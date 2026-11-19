# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

class RailsCredentialsTest < Minitest::Test
  include TestHelpers

  def test_nested_credentials
    applied = TypeSafe::RailsCredentials.apply({ typesafe: { api_key: " ts_key ", model: "jev-1.14" } })
    assert_equal %i[api_key model], applied
    assert_equal "ts_key", TypeSafe.configuration.api_key
    assert_equal "jev-1.14", TypeSafe::Client.new.model
  end

  def test_flat_credentials
    TypeSafe::RailsCredentials.apply({ typesafe_api_key: "flat_key" })
    assert_equal "flat_key", TypeSafe.configuration.api_key
  end

  def test_does_not_override_explicit_configuration
    TypeSafe.configure { |c| c.api_key = "explicit" }
    assert_empty TypeSafe::RailsCredentials.apply({ typesafe: { api_key: "from_credentials" } })
    assert_equal "explicit", TypeSafe.configuration.api_key
  end

  def test_ignores_missing_or_malformed_credentials
    assert_empty TypeSafe::RailsCredentials.apply(nil)
    assert_empty TypeSafe::RailsCredentials.apply({})
    assert_empty TypeSafe::RailsCredentials.apply({ typesafe: "oops" })
    assert_nil TypeSafe.configuration.api_key
  end

  # Boots a real Rails app with encrypted credentials in a subprocess.
  def test_railtie_loads_encrypted_credentials
    Dir.mktmpdir do |dir|
      script = <<~RUBY
        require "rails"
        require "active_support/encrypted_configuration"
        Dir.mkdir("#{dir}/config")
        File.write("#{dir}/config/master.key", ActiveSupport::EncryptedConfiguration.generate_key)
        ActiveSupport::EncryptedConfiguration.new(
          config_path: "#{dir}/config/credentials.yml.enc", key_path: "#{dir}/config/master.key",
          env_key: "RAILS_MASTER_KEY", raise_if_missing_key: true
        ).write("typesafe:\\n  api_key: ts_from_rails\\n  model: jev-rails\\n")

        require "typesafe"
        class App < Rails::Application
          config.root = "#{dir}"
          config.credentials.content_path = "#{dir}/config/credentials.yml.enc"
          config.credentials.key_path = "#{dir}/config/master.key"
          config.eager_load = false
          config.logger = Logger.new(nil)
          config.secret_key_base = "x" * 64
        end
        Rails.application.initialize!
        print [TypeSafe.client.model, TypeSafe.configuration.api_key].join(",")
      RUBY
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
      assert status.success?, err
      assert_equal "jev-rails,ts_from_rails", out
    end
  end
end
