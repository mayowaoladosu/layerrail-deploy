# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "lrail_orchestrator"
require "rspec"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
end
