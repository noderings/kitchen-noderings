# frozen_string_literal: true

require_relative "lib/kitchen/driver/noderings_version"

Gem::Specification.new do |spec|
  spec.name = "kitchen-noderings"
  spec.version = Kitchen::Driver::NODERINGS_VERSION
  spec.authors = ["NodeRings"]
  spec.email = ["partners@noderings.com"]
  spec.summary = "A Test Kitchen driver for NodeRings virtual machines"
  spec.description = "Runs Test Kitchen instances on NodeRings marketplace virtual machines: orders the " \
                     "cheapest matching offer, waits for SSH, and deletes the server and its temporary key afterwards."
  spec.homepage = "https://github.com/noderings/kitchen-noderings"
  spec.license = "Apache-2.0"

  spec.files = %w{LICENSE README.md CHANGELOG.md} + Dir.glob("lib/**/*.rb")
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}#readme",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true",
  }

  # The driver talks to the API with the Ruby standard library only.
  spec.add_dependency "test-kitchen", ">= 3.0", "< 5"
end
