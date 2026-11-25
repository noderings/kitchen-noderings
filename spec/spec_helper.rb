# frozen_string_literal: true

require "logger"
require "stringio"
require "tmpdir"
require "kitchen"
require "kitchen/driver/noderings"
require_relative "support/fake_noderings"

RSpec.configure do |config|
  config.before do
    @fake = FakeNodeRings.new
    Kitchen::Driver::Noderings.transport = @fake
    Kitchen::Driver::Noderings.sleeper = ->(_s) {}
  end
end
