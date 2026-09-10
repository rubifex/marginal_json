# frozen_string_literal: true

require_relative "lib/kochab/version"

Gem::Specification.new do |spec|
  spec.name = "kochab"
  spec.version = Kochab::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "Recoverable JSONC parsing and edits that preserve comments and formatting"
  spec.description = "A Ruby JSONC parser with byte ranges, syntax recovery, source queries, " \
    "minimal text edits, formatting, and UTF-16 positions. No runtime gem dependencies."
  spec.homepage = "https://github.com/noxdea/kochab"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "examples/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]
end
