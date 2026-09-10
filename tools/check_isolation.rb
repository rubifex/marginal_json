# frozen_string_literal: true

require "rubygems"

root = File.expand_path("..", __dir__)
Dir[File.join(root, "lib/**/*.rb")].each do |path|
  abort "Application dependency in #{path}" if File.read(path).match?(/\b(?:Tessera|Quire)\b/)
end
spec = Gem::Specification.load(File.join(root, "kochab.gemspec"))
abort "Unexpected runtime dependency" unless spec.runtime_dependencies.empty?
puts "Standalone library; no runtime gem dependencies"
