# frozen_string_literal: true

module TypeSafe
  # Structural checks for successful API responses. Failures raise
  # ResponseValidationError with the offending field path; the client fills in
  # the HTTP metadata.
  module Validation
    # Raised internally, then converted to ResponseValidationError by the client.
    class Failure < StandardError
      attr_reader :field_path

      def initialize(message, field_path)
        @field_path = field_path
        super(message)
      end
    end

    module_function

    def error(message, path)
      Failure.new(message, path)
    end

    def hash!(value, path)
      raise error("expected an object", path) unless value.is_a?(Hash)

      value
    end

    def array!(value, path)
      raise error("expected an array", path) unless value.is_a?(Array)

      value
    end

    def string!(hash, key, path)
      value = hash[key]
      raise error("expected a string", path) unless value.is_a?(String)

      value
    end

    def number!(hash, key, path, nullable: false)
      value = hash[key]
      return nil if nullable && value.nil?
      raise error("expected a number", path) unless value.is_a?(Numeric)

      value
    end

    def integer!(hash, key, path)
      value = hash[key]
      raise error("expected an integer", path) unless value.is_a?(Integer)

      value
    end
  end
end
