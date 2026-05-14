# frozen_string_literal: true

require_relative "lib/errorgap/version"

Gem::Specification.new do |spec|
  spec.name = "errorgap"
  spec.version = Errorgap::VERSION
  spec.authors = ["Errorgap"]
  spec.email = ["support@example.com"]

  spec.summary = "Ruby notifier for Errorgap error tracking."
  spec.description = "Captures Ruby exceptions and sends them to a Errorgap server."
  spec.homepage = "https://github.com/jGRUBBS/errorgap-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt"]
  end
  spec.bindir = "exe"
  spec.executables = ["errorgap"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
end
