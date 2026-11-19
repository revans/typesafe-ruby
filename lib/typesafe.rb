# frozen_string_literal: true

require_relative "typesafe/version"
require_relative "typesafe/errors"
require_relative "typesafe/retry_policy"
require_relative "typesafe/questions"
require_relative "typesafe/image"
require_relative "typesafe/types/validation"
require_relative "typesafe/types/answers"
require_relative "typesafe/types/system_one_response"
require_relative "typesafe/types/model_list"
require_relative "typesafe/request_builder"
require_relative "typesafe/http"
require_relative "typesafe/resources/models"
require_relative "typesafe/client"
require_relative "typesafe/rails_credentials"
require_relative "typesafe/railtie" if defined?(Rails::Railtie)

# Ruby client for TypeSafe's System One API (the Jev models).
#
#   TypeSafe.configure { |c| c.api_key = ENV["TYPESAFE_API_KEY"] }
#
#   result = TypeSafe.system_one(
#     state: "I was charged twice. Please help ASAP.",
#     questions: {
#       billing: TypeSafe.noul("Is this about billing?"),
#       tone: TypeSafe.choice("What is the tone?", criteria: %w[calm angry]),
#       urgency: TypeSafe.score("How urgent is this?", criteria: %w[low medium high])
#     }
#   )
module TypeSafe
  API_KEY_ENV = "TYPESAFE_API_KEY"
  BASE_URL_ENV = "TYPESAFE_BASE_URL"
  DEFAULT_MODEL_ENV = "TYPESAFE_DEFAULT_MODEL"
  LOG_LEVEL_ENV = "TYPESAFE_LOG_LEVEL"
  DEFAULT_BASE_URL = "https://api.typesafe.ai"
  DEFAULT_MODEL = "jev-latest"
  DEFAULT_TIMEOUT = 10.0
  USER_AGENT = "typesafe-ruby/#{VERSION} ruby/#{RUBY_VERSION}".freeze

  # Process-wide defaults used by every Client (explicit Client options win).
  class Configuration
    attr_accessor :api_key, :base_url, :model, :timeout, :retry_policy, :headers, :compression,
                  :image_upload, :images, :long_context, :logger

    def initialize
      @compression = :gzip
    end
  end

  extend QuestionHelpers

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    # TypeSafe.configure do |c|
    #   c.api_key = Rails.application.credentials.typesafe_api_key
    #   c.model = "jev-latest"
    # end
    def configure
      yield configuration
      @client = nil
      configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
      @client = nil
    end

    # A shared default client built from the configuration.
    def client
      @client ||= Client.new
    end

    def system_one(...) = client.system_one(...)
    def ask(...) = client.system_one(...)
    def models = client.models
    def list_models(...) = client.list_models(...)
  end
end
