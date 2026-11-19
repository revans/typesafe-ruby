# frozen_string_literal: true

module TypeSafe
  # Copies TypeSafe settings from Rails encrypted credentials into
  # TypeSafe.configuration. Two layouts are supported:
  #
  #   # bin/rails credentials:edit
  #   typesafe:
  #     api_key: ts_live_...
  #     model: jev-latest              # optional
  #     base_url: https://...          # optional
  #
  #   # or, flat:
  #   typesafe_api_key: ts_live_...
  #
  # Values already set with TypeSafe.configure are never overwritten.
  module RailsCredentials
    KEYS = %i[api_key model base_url].freeze

    module_function

    # @param credentials [#dig, #[]] e.g. Rails.application.credentials
    # @return [Array<Symbol>] the settings that were applied
    def apply(credentials, config = TypeSafe.configuration)
      return [] unless credentials

      KEYS.each_with_object([]) do |key, applied|
        next unless blank?(config.public_send(key))

        value = lookup(credentials, key)
        next if blank?(value)

        config.public_send(:"#{key}=", value.to_s.strip)
        applied << key
      end
    end

    def lookup(credentials, key)
      nested = credentials.dig(:typesafe, key) if credentials.respond_to?(:dig)
      nested = credentials.dig(:typesafe, key.to_s) if blank?(nested) && credentials.respond_to?(:dig)
      return nested unless blank?(nested)

      credentials[:"typesafe_#{key}"] if credentials.respond_to?(:[])
    rescue TypeError, NoMethodError
      nil # e.g. `typesafe:` holds a string rather than a hash
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:strip) && value.strip.empty?)
    end
  end
end
