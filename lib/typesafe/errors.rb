# frozen_string_literal: true

require "time"

module TypeSafe
  # Base class for every error raised by this gem.
  class Error < StandardError; end

  # The client was configured incorrectly (missing API key, bad option, ...).
  class ConfigurationError < Error; end

  # An unsuccessful HTTP response, with its body and request metadata.
  class APIError < Error
    attr_reader :status, :body, :headers, :endpoint

    def initialize(message = nil, status:, body: nil, headers: {}, endpoint: nil)
      @status = status
      @body = body
      @headers = headers || {}
      @endpoint = endpoint
      super(message || self.class.default_message(status, body))
    end

    # The +x-typesafe-request-id+ response header, if present. Include it when
    # reporting problems to TypeSafe.
    def request_id
      headers["x-typesafe-request-id"]
    end

    # The +detail+ field of the JSON error body, when present.
    def detail
      body.is_a?(Hash) ? body["detail"] : nil
    end

    def self.default_message(status, body)
      detail = body.is_a?(Hash) ? body["detail"] : body
      text = case detail
             when nil, "" then nil
             when String then detail
             when Array
               detail.map do |e|
                 e.is_a?(Hash) ? [Array(e["loc"]).join("."), e["msg"]].compact.join(": ") : e.to_s
               end.join("; ")
             else JSON.generate(detail)
             end
      ["HTTP #{status}", text].compact.join(": ")
    end
  end

  # 400: the body broke a request rule (encoding, nesting, non-finite number,
  # malformed compression, images not enabled, ...).
  class BadRequestError < APIError; end

  # 400 with +max_tokens_exceeded+: the request is longer than the model's
  # context length. Consider +long_context: true+.
  class ContextLengthExceededError < BadRequestError; end

  # 401: missing or invalid API key.
  class AuthenticationError < APIError; end

  # 403: the key is not allowed to perform this request.
  class PermissionDeniedError < APIError; end

  # 404: the resource was not found.
  class NotFoundError < APIError; end

  # 413: the body is over 32 MiB.
  class PayloadTooLargeError < APIError; end

  # 415: unsupported Content-Encoding or more than one compression layer.
  class UnsupportedMediaTypeError < APIError; end

  # 422: the request failed schema validation.
  class UnprocessableEntityError < APIError
    # Array of +{"loc" => [...], "msg" => "...", "type" => "..."}+ hashes.
    def validation_errors
      detail.is_a?(Array) ? detail : []
    end
  end

  # 429: rate limit exceeded.
  class RateLimitError < APIError
    # The server's requested wait in milliseconds, or nil.
    def retry_after_ms
      RetryAfter.parse_ms(headers)
    end
  end

  # 5xx: the server failed to process the request.
  class InternalServerError < APIError; end

  # 529: TypeSafe is temporarily overloaded.
  class OverloadedError < InternalServerError; end

  # A 2xx response whose body was missing or structurally invalid.
  class ResponseValidationError < APIError
    attr_reader :field_path

    def initialize(message, field_path:, **)
      @field_path = field_path
      super("#{message} (at #{field_path})", **)
    end
  end

  # The request failed without an HTTP response (DNS, refused, reset, TLS, ...).
  class APIConnectionError < Error
    attr_reader :endpoint

    def initialize(message = "Connection error", endpoint: nil)
      @endpoint = endpoint
      super(message)
    end
  end

  # The request exceeded its configured timeout.
  class APITimeoutError < APIConnectionError
    attr_reader :timeout

    def initialize(message = "Request timed out", timeout: nil, endpoint: nil)
      @timeout = timeout
      super(message, endpoint: endpoint)
    end
  end

  # Maps HTTP statuses to error classes.
  module ErrorMapper
    module_function

    STATUS_CLASSES = {
      400 => BadRequestError,
      401 => AuthenticationError,
      403 => PermissionDeniedError,
      404 => NotFoundError,
      413 => PayloadTooLargeError,
      415 => UnsupportedMediaTypeError,
      422 => UnprocessableEntityError,
      429 => RateLimitError,
      529 => OverloadedError
    }.freeze

    def build(status:, body:, headers:, endpoint:)
      klass = STATUS_CLASSES[status]
      klass = ContextLengthExceededError if klass == BadRequestError && context_length?(body)
      klass ||= status >= 500 ? InternalServerError : APIError
      klass.new(status: status, body: body, headers: headers, endpoint: endpoint)
    end

    def context_length?(body)
      text = body.is_a?(String) ? body : JSON.generate(body)
      text.include?("max_tokens_exceeded")
    rescue StandardError
      false
    end
  end

  # Parses Retry-After / retry-after-ms headers.
  module RetryAfter
    module_function

    # Returns milliseconds or nil. +headers+ must have lowercase keys.
    def parse_ms(headers)
      if (ms = headers["retry-after-ms"])
        value = Float(ms, exception: false)
        return value if value && value >= 0
      end
      return nil unless (raw = headers["retry-after"])

      seconds = Float(raw, exception: false)
      return seconds * 1000 if seconds && seconds >= 0

      begin
        delta = Time.httpdate(raw) - Time.now
        delta.positive? ? delta * 1000 : 0.0
      rescue ArgumentError
        nil
      end
    end
  end
end
