# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

desc "Run the unit tests"
RSpec::Core::RakeTask.new(:spec)

begin
  require "cookstyle/chefstyle"
  require "rubocop/rake_task"
  RuboCop::RakeTask.new(:style) { |task| task.options += ["--display-cop-names", "--no-color"] }
rescue LoadError
  puts "cookstyle is not installed. Run bundle install first."
end

task default: %i{spec style}
