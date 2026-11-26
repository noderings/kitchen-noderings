# frozen_string_literal: true

RSpec.describe Kitchen::Driver::Noderings do
  let(:kitchen_root) { Dir.mktmpdir }
  let(:log) { StringIO.new }
  let(:logger) { Logger.new(log) }
  let(:connection) { double("connection", wait_until_ready: true) }
  let(:transport) { double("transport", :[] => nil, :name => "Ssh") }
  let(:platform) { double("platform", name: platform_name) }
  let(:platform_name) { "ubuntu-24.04" }
  let(:config) do
    { noderings_api_token: "test-token", plan: "SC-GC-1C-1G-20", country: "United States", city: "Ashburn",
      kitchen_root: kitchen_root }
  end
  let(:instance) do
    double("instance", name: "default-ubuntu-2404", platform: platform, transport: transport, logger: logger,
      to_str: "<default-ubuntu-2404>")
  end
  let(:driver) { described_class.new(config).finalize_config!(instance) }
  let(:state) { {} }

  before do
    allow(transport).to receive(:connection) { |_state, &block| block&.call(connection) }
  end

  after { FileUtils.rm_rf(kitchen_root) }

  it "is a version 2 driver that reports its version" do
    expect(described_class.instance_variable_get(:@api_version)).to eq 2
    expect(driver.diagnose_plugin[:version]).to eq Kitchen::Driver::NODERINGS_VERSION
  end

  describe "defaults" do
    it "maps the platform name to a distro" do
      expect(driver[:distro]).to eq "ubuntu_24_04"
    end

    context "on Rocky Linux" do
      let(:platform_name) { "rockylinux-9" }

      it("uses the NodeRings name") { expect(driver[:distro]).to eq "rocky_9" }
    end

    it "names servers after the instance, within one DNS label" do
      expect(driver[:server_name]).to match(/\Akitchen-default-ubuntu-2404-[a-z0-9]{6}\z/)
      long = described_class.new(config).finalize_config!(double("instance", name: "x" * 80, platform: platform,
        transport: transport, logger: logger, to_str: "i"))
      expect(long[:server_name].length).to be <= 63
    end

    it "reads the token from the environment" do
      ENV["NODERINGS_TOKEN"] = "env-token"
      expect(described_class.new(config.except(:noderings_api_token)).finalize_config!(instance)[:noderings_api_token]).to eq "env-token"
    ensure
      ENV.delete("NODERINGS_TOKEN")
    end
  end

  describe "#create" do
    it "orders the cheapest offer with a temporary key and waits for SSH" do
      driver.create(state)
      vm = @fake.vms.values.first
      body = @fake.created_vm_bodies.last
      expect(body).to include("hostname" => state[:server_name], "planId" => FakeNodeRings::PLAN_ID,
        "distro" => "DISTRO_UBUNTU_24_04", "tags" => ["test-kitchen"])
      key = @fake.ssh_keys.values.first
      expect(body["sshKeyIds"]).to eq [key["id"]]
      expect(state[:server_name]).to match(/\Akitchen-default-ubuntu-2404-/)
      expect(key["name"]).to eq "kitchen-#{state[:server_name]}"
      expect(key["publicKey"]).to start_with("ssh-rsa ")
      expect(state).to include(server_id: vm["id"], hostname: "192.0.2.50", username: "root", port: 22,
        noderings_ssh_key_id: key["id"])
      expect(File.stat(state[:ssh_key]).mode & 0o777).to eq 0o600
      expect(connection).to have_received(:wait_until_ready)
      expect(@fake.calls.last[4]["User-Agent"]).to start_with("kitchen-noderings/")
    end

    it "uses the transport's key when one is configured" do
      path = File.join(kitchen_root, "id_test")
      File.write(path, OpenSSL::PKey::RSA.generate(2048).to_pem)
      File.write("#{path}.pub", "ssh-rsa AAAAPUBLIC me@host\n")
      allow(transport).to receive(:[]).with(:ssh_key).and_return(path)
      driver.create(state)
      expect(@fake.ssh_keys.values.first["publicKey"]).to eq "ssh-rsa AAAAPUBLIC"
      expect(state).not_to have_key(:ssh_key)
    end

    it "uses named NodeRings keys instead of uploading one" do
      @fake.ssh_keys["k1"] = { "id" => "k1", "name" => "laptop", "publicKey" => "ssh-ed25519 AAAA" }
      config[:noderings_ssh_keys] = ["laptop"]
      driver.create(state)
      expect(@fake.created_vm_bodies.last["sshKeyIds"]).to eq ["k1"]
      expect(@fake.ssh_keys.length).to eq 1
    end

    it "attaches a firewall ruleset" do
      @fake.call("POST", "https://api.noderings.com/v1/firewall/rulesets", {}, '{"ruleset":{"name":"ssh"}}', 1)
      config[:firewall_ruleset] = "ssh"
      driver.create(state)
      expect(@fake.vms.values.first["firewallRulesetId"]).to eq @fake.rulesets.keys.first
    end

    it "does nothing when the server already exists" do
      driver.create(server_id: "abc")
      expect(@fake.calls).to be_empty
    end

    context "with hosting_provider" do
      [FakeNodeRings::ACME_ID, "acme-hosting", "Acme Hosting", "  acme HOSTING "].each do |provider|
        it "orders from the provider given as #{provider.inspect}" do
          config[:hosting_provider] = provider
          driver.create(state)
          expect(@fake.created_vm_bodies.last).to include("planId" => FakeNodeRings::ACME_PLAN_ID,
            "regionId" => FakeNodeRings::ACME_REGION_ID)
        end
      end

      it "orders the cheapest offer without one" do
        driver.create(state)
        expect(@fake.created_vm_bodies.last["planId"]).to eq FakeNodeRings::PLAN_ID
      end

      it "fails for an unknown provider" do
        config[:hosting_provider] = "Nobody Hosting"
        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed, /from provider Nobody Hosting/)
        expect(@fake.created_vm_bodies).to be_empty
      end

      it "refuses a provider name two providers share" do
        @fake.extra_providers << FakeNodeRings::ACME_OFFER.merge("organizationId" => "66666666-6666-6666-6666-666666666666")
        config[:hosting_provider] = "acme hosting"
        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed, /more than one provider is named acme hosting/)
        expect(@fake.created_vm_bodies).to be_empty
      end
    end

    it "explains a missing offer" do
      config[:city] = "Nowhere"
      expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed, /No offer for plan code SC-GC-1C-1G-20 in Nowhere/)
    end

    it "needs a token, but only when creating" do
      config.delete(:noderings_api_token)
      expect(driver[:noderings_api_token]).to be_nil
      expect { driver.create(state) }.to raise_error(Kitchen::UserError, /needs a NodeRings API token/)
    end

    it "needs plan, country and city" do
      config.delete(:plan)
      expect { driver.create(state) }.to raise_error(Kitchen::UserError, /needs plan, country and city/)
    end
  end

  describe "#destroy" do
    it "deletes the server, the temporary key and the key file" do
      driver.create(state)
      key_file = state[:ssh_key]
      driver.destroy(state)
      expect(@fake.vms).to be_empty
      expect(@fake.ssh_keys).to be_empty
      expect(File.exist?(key_file)).to be false
      expect(state).to be_empty.or eq(username: "root", port: 22)
    end

    it "tolerates a server that is already gone" do
      driver.destroy(server_id: "00000000-0000-0000-0000-000000000000")
      expect(log.string).to include("destroyed")
    end
  end

  describe "#status" do
    it "reports the power state" do
      driver.create(state)
      expect(driver.status(state)).to include(live: true, state: "running", source: "driver")
    end
  end

  describe "#doctor" do
    it "passes with a token the API accepts" do
      expect(driver.doctor({})).to be false
    end
  end
end
