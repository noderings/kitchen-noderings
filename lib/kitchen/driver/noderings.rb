# frozen_string_literal: true

#
# Copyright:: NodeRings
# License:: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "kitchen"
require "fileutils" unless defined?(FileUtils)
require "openssl" unless defined?(OpenSSL)
require "securerandom" unless defined?(SecureRandom)
require "time" unless defined?(Time.now.iso8601)
require_relative "noderings_version"
require_relative "noderings/compute"

module Kitchen
  module Driver
    # Test Kitchen driver that runs instances on NodeRings virtual machines.
    #
    # {#create} orders the cheapest matching marketplace offer, waits for an
    # address and for SSH to answer; {#destroy} deletes the server and the
    # temporary SSH key the driver uploaded for it.
    #
    # @example Minimal kitchen.yml
    #   driver:
    #     name: noderings
    #     plan: SC-GC-1C-1G-20
    #     country: United States
    #     city: Ashburn
    #
    #   platforms:
    #     - name: ubuntu-24.04
    class Noderings < Kitchen::Driver::Base
      kitchen_driver_api_version 2

      plugin_version Kitchen::Driver::NODERINGS_VERSION

      # Test Kitchen platform names that differ from the NodeRings distro name.
      # Any other platform name is used as the distro, so ubuntu-24.04 becomes
      # ubuntu_24_04 and debian-13 becomes debian_13.
      PLATFORM_DISTROS = {
        "centos-stream-9" => "centos_9",
        "centos-stream-10" => "centos_10",
        "rockylinux-9" => "rocky_9",
        "rockylinux-10" => "rocky_10",
      }.freeze

      # A hostname is one DNS label.
      MAX_SERVER_NAME_LENGTH = 63

      default_config :username, "root"
      default_config :port, 22
      default_config :billing_type, "usage"
      default_config :sort, "price"
      default_config :provider_id, nil
      default_config :plan, nil
      default_config :country, nil
      default_config :city, nil
      default_config :plan_id, nil
      default_config :region_id, nil
      default_config :noderings_ssh_keys, []
      default_config :firewall_ruleset, nil
      default_config :tags, ["test-kitchen"]
      default_config :server_wait_timeout, 900
      default_config(:distro, &:default_distro)
      default_config(:server_name, &:default_name)

      default_config :noderings_api_token do
        KitchenNoderings::TOKEN_ENV_VARS.map { |v| ENV[v] }.find { |v| !v.to_s.empty? }
      end

      default_config :noderings_api_url do
        ENV["NODERINGS_API_URL"]
      end

      default_config :noderings_organization_id do
        ENV["NODERINGS_ORGANIZATION_ID"]
      end

      # Tests plug an in-memory API in here.
      class << self
        attr_accessor :transport, :sleeper
      end

      # Orders a server and waits until SSH answers.
      #
      # Idempotent: when state already names a server, nothing is ordered, so a
      # retried kitchen create does not leave the first server behind.
      #
      # @param state [Hash] mutable instance state
      # @raise [Kitchen::ActionFailed] if the order or a wait fails
      def create(state)
        if state[:server_id]
          info("NodeRings server <#{state[:server_id]}> already created.")
          return
        end

        validate_token_config!
        validate_offer_config!
        # Lazy config defaults are evaluated on every read, so fix the random name once.
        state[:server_name] = config[:server_name]
        key_ids = ssh_key_ids(state)
        plan_id, region_id, offer = select_offer

        info("Ordering NodeRings server #{state[:server_name]} (#{offer}, #{distro})")
        vm = api("ordering #{state[:server_name]}") do
          compute.order_vm(client, state[:server_name], plan_id, region_id,
            distro: distro, ssh_key_ids: key_ids, tags: Array(config[:tags]),
            wait: false, timeout: config[:server_wait_timeout])
        end
        state[:server_id] = vm["id"]
        info("NodeRings server <#{state[:server_id]}> created.")

        vm = api("waiting for #{state[:server_name]}") { compute.wait_address(client, vm["id"], config[:server_wait_timeout]) }
        unless config[:firewall_ruleset].to_s.empty?
          ruleset_id = api("resolving the firewall ruleset") { compute.resolve_ruleset(client, config[:firewall_ruleset]) }
          vm = api("attaching the firewall") { compute.attach_firewall(client, vm["id"], ruleset_id, timeout: config[:server_wait_timeout]) }
        end

        state[:hostname] = vm["ipv4"].to_s.empty? ? vm["ipv6"] : vm["ipv4"]
        state[:username] = config[:username]
        state[:port] = config[:port]
        info("NodeRings server <#{state[:server_id]}> has address #{state[:hostname]}; waiting for SSH")
        instance.transport.connection(state, &:wait_until_ready)
        info("(ssh ready)")
      end

      # Deletes the server and the temporary SSH key named in state.
      #
      # @param state [Hash] mutable instance state; the driver's keys are removed
      def destroy(state)
        delete_server(state[:server_id]) if state[:server_id]
        delete_temporary_key(state)
        %i{server_id server_name hostname noderings_ssh_key_id ssh_key}.each { |k| state.delete(k) }
      end

      # The NodeRings distro for this platform.
      #
      # @return [String] such as ubuntu_24_04
      def default_distro
        name = instance.platform.name
        KitchenNoderings::Compute.normalize_distro(PLATFORM_DISTROS.fetch(name, name))
      end

      # A server name unique enough to run many instances side by side.
      #
      # @return [String] a hostname of at most 63 characters
      def default_name
        base = "kitchen-#{instance.name}".downcase.gsub(/[^a-z0-9-]+/, "-").squeeze("-")
        suffix = SecureRandom.alphanumeric(6).downcase
        "#{base[0, MAX_SERVER_NAME_LENGTH - suffix.length - 1].chomp("-")}-#{suffix}"
      end

      # What NodeRings reports about the server.
      #
      # @param state [Hash] instance state naming the server
      # @return [Hash] a Test Kitchen status hash
      def status(state)
        return super unless state[:server_id]

        vm = begin
          compute.find_vm(client, state[:server_id])
             rescue KitchenNoderings::APIError, KitchenNoderings::UsageError, *KitchenNoderings::CONNECTION_ERRORS
               nil
        end
        return super unless vm

        power = compute.power_state(vm)
        {
          live: power == "running",
          state: power,
          source: "driver",
          resource_id: state[:server_id].to_s,
          message: "NodeRings reports the server as #{power}",
          checked_at: Time.now.utc.iso8601,
        }
      end

      # Checks the token and offer settings before anything is billed.
      #
      # @return [Boolean] true when a problem was reported
      def doctor(_state)
        problems = []
        begin
          client.organization
        rescue ::StandardError => e
          problems << "NodeRings rejected the configured API token: #{e.message}"
        end
        begin
          validate_offer_config!
        rescue Kitchen::UserError => e
          problems << e.message
        end
        problems.each { |p| warn(p) }
        !problems.empty?
      end

      private

      def compute
        KitchenNoderings::Compute
      end

      def client
        @client ||= KitchenNoderings::Client.new(
          token: config[:noderings_api_token],
          api_url: config[:noderings_api_url],
          organization_id: config[:noderings_organization_id],
          user_agent: "kitchen-noderings/#{Kitchen::Driver::NODERINGS_VERSION} (test-kitchen #{Kitchen::VERSION})",
          transport: self.class.transport,
          sleeper: self.class.sleeper
        )
      end

      def distro
        KitchenNoderings::Compute.normalize_distro(config[:distro])
      end

      # Runs an API call and turns a failure into an ActionFailed.
      def api(what)
        yield
      # ::StandardError subclasses only: Kitchen defines its own StandardError.
      rescue KitchenNoderings::APIError, KitchenNoderings::UsageError, KitchenNoderings::WaitTimeout => e
        raise ActionFailed, "NodeRings: #{what}: #{e.message}"
      end

      # Checked when an instance is created, not when kitchen.yml is loaded, so
      # kitchen list and kitchen diagnose work without a token.
      def validate_token_config!
        return unless config[:noderings_api_token].to_s.empty?

        raise UserError, "kitchen-noderings needs a NodeRings API token: export NODERINGS_TOKEN, or set " \
          "noderings_api_token in the driver config"
      end

      def validate_offer_config!
        return if config[:plan_id] && config[:region_id]
        return if config[:plan] && config[:country] && config[:city]

        raise UserError, "kitchen-noderings needs plan, country and city (or plan_id and region_id) in the driver config"
      end

      def select_offer
        return [config[:plan_id], config[:region_id], "plan #{config[:plan_id]}"] if config[:plan_id] && config[:region_id]

        plan_id, region_id, offer = api("finding an offer") do
          compute.choose_offer(client, config[:plan], config[:country], config[:city],
            billing_type: config[:billing_type], provider_id: config[:provider_id], sort: config[:sort])
        end
        [plan_id, region_id, "#{config[:plan]} from #{offer["provider_name"]} in #{config[:city]}, #{config[:country]}"]
      end

      # IDs of the keys to install. Without noderings_ssh_keys, the driver
      # uploads the transport's key (or one it generates) as a temporary key.
      def ssh_key_ids(state)
        named = Array(config[:noderings_ssh_keys])
        return api("resolving SSH keys") { compute.resolve_ssh_keys(client, named) } unless named.empty?

        path = instance.transport[:ssh_key] || generate_key(state)
        public_key = public_key_for(path)
        key = api("uploading a temporary SSH key") { client.create_ssh_key("kitchen-#{state[:server_name]}", public_key) }
        state[:noderings_ssh_key_id] = key["id"]
        debug("uploaded temporary NodeRings SSH key #{key["id"]}")
        [key["id"]]
      end

      # Writes a fresh RSA key next to the instance state and points the transport at it.
      def generate_key(state)
        path = File.join(config[:kitchen_root], ".kitchen", "#{instance.name}-noderings.pem")
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "w", 0o600) { |f| f.write(OpenSSL::PKey::RSA.generate(3072).to_pem) }
        state[:ssh_key] = path
        path
      end

      # The OpenSSH public key for a private key file.
      def public_key_for(path)
        pub = "#{path}.pub"
        return File.read(pub).split[0, 2].join(" ") if File.exist?(pub)

        require "net/ssh" unless defined?(Net::SSH)
        key = Net::SSH::KeyFactory.load_private_key(File.expand_path(path), nil, false)
        "#{key.ssh_type} #{[key.public_key.to_blob].pack("m0")}"
      end

      def delete_server(server_id)
        api("deleting NodeRings server <#{server_id}>") do
          compute.waiter(client, config[:server_wait_timeout]).retry_busy do
            client.delete_virtual_machine(server_id)
          rescue KitchenNoderings::APIError => e
            raise unless e.not_found?
          end
        end
        info("NodeRings server <#{server_id}> destroyed.")
      end

      def delete_temporary_key(state)
        if state[:noderings_ssh_key_id]
          api("deleting the temporary SSH key") do
            client.delete_ssh_key(state[:noderings_ssh_key_id])
          rescue KitchenNoderings::APIError => e
            raise unless e.not_found?
          end
        end
        FileUtils.rm_f([state[:ssh_key], "#{state[:ssh_key]}.pub"]) if state[:ssh_key]
      end
    end
  end
end
