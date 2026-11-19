# frozen_string_literal: true

require_relative "lib/typesafe/version"

Gem::Specification.new do |spec|
  spec.name = "typesafe"
  spec.version = TypeSafe::VERSION
  spec.authors = ["Gierd"]
  spec.summary = "Ruby client for the TypeSafe System One API (Jev)."
  spec.description = <<~DESC
    A dependency-free Ruby client for TypeSafe's System One API. Ask Jev typed
    questions (Noul, Choice, Score, Box) about your state and get structured,
    calibrated answers back. Supports images, multipart uploads, compression,
    retries with backoff, and typed errors.
  DESC
  spec.homepage = "https://docs.typesafe.ai"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["documentation_uri"] = "https://docs.typesafe.ai"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "base64"
  spec.add_dependency "json", ">= 2.6"
  spec.add_dependency "logger"
end
