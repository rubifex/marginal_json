# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |test|
  test.libs << "test"
  test.pattern = "test/**/*_test.rb"
end

task default: :test

namespace :test do
  desc "Run every pinned JSONTestSuite case against strict mode"
  task :oracle do
    ruby "-Ilib:test", "test/json_suite_test.rb"
  end

  desc "Run recovery, random-byte, and generated JSON checks"
  task :fuzz do
    ruby "-Ilib:test", "test/recovery_test.rb"
  end
end

desc "Measure parser, query, and edit performance"
task :bench do
  ruby "--yjit", "bench/benchmark.rb"
end

namespace :bench do
  desc "Check the documented performance budgets"
  task :assert do
    ruby "--yjit", "bench/benchmark.rb", "--assert"
  end
end

desc "Check runtime dependencies and independence from the application"
task :isolation do
  ruby "tools/check_isolation.rb"
end
