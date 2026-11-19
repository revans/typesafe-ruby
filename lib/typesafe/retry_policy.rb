# frozen_string_literal: true

module TypeSafe
  # Controls how failed requests are retried. Defaults mirror TypeSafe's
  # official SDKs: 2 retries, exponential backoff from 0.5s up to 5s with 25%
  # jitter, retrying 408/429/5xx plus connection errors and timeouts, honoring
  # Retry-After headers, with a 30 second overall budget.
  #
  #   TypeSafe::Client.new(retry_policy: TypeSafe::RetryPolicy.new(max_retries: 5))
  #   TypeSafe::Client.new(retry_policy: TypeSafe::RetryPolicy.none)
  class RetryPolicy
    DEFAULT_HTTP_STATUSES = [408, 429, *(500..599)].freeze

    attr_reader :max_retries, :backoff_initial, :backoff_max, :backoff_jitter,
                :http_statuses, :respect_retry_after, :connection_errors,
                :timeout_errors, :exceptions, :predicate, :timeout

    # @param max_retries [Integer] retries after the first attempt; 0 disables retries
    # @param backoff_initial [Float] first delay in seconds, doubled each attempt
    # @param backoff_max [Float] maximum delay in seconds
    # @param backoff_jitter [Float] fraction (0..1) of each delay randomly subtracted
    # @param http_statuses [Enumerable<Integer>] statuses that are retried
    # @param respect_retry_after [Boolean] honor Retry-After / retry-after-ms
    # @param connection_errors [Boolean] retry APIConnectionError
    # @param timeout_errors [Boolean] retry APITimeoutError
    # @param exceptions [Array<Class>] extra exception classes to retry
    # @param predicate [#call, nil] called with the error; truthy forces a retry
    # @param timeout [Float, nil] overall time budget in seconds across all attempts
    def initialize(max_retries: 2, backoff_initial: 0.5, backoff_max: 5.0, backoff_jitter: 0.25,
                   http_statuses: DEFAULT_HTTP_STATUSES, respect_retry_after: true,
                   connection_errors: true, timeout_errors: true, exceptions: [],
                   predicate: nil, timeout: 30.0)
      raise ArgumentError, "max_retries must be >= 0" if max_retries.negative?
      raise ArgumentError, "backoff_jitter must be between 0 and 1" unless (0..1).cover?(backoff_jitter)

      @max_retries = max_retries
      @backoff_initial = backoff_initial.to_f
      @backoff_max = backoff_max.to_f
      @backoff_jitter = backoff_jitter.to_f
      @http_statuses = http_statuses.to_a.freeze
      @respect_retry_after = respect_retry_after
      @connection_errors = connection_errors
      @timeout_errors = timeout_errors
      @exceptions = exceptions.to_a.freeze
      @predicate = predicate
      @timeout = timeout
      freeze
    end

    # A policy that never retries.
    def self.none
      new(max_retries: 0)
    end

    # Whether +error+ should be retried (ignoring attempt counts and budget).
    def retryable?(error)
      return true if predicate&.call(error)
      return true if exceptions.any? { |klass| error.is_a?(klass) }

      case error
      when APITimeoutError then timeout_errors
      when APIConnectionError then connection_errors
      when APIError then http_statuses.include?(error.status)
      else false
      end
    end

    # Seconds to wait before retry number +retry_index+ (0-based).
    def delay_for(retry_index, error = nil, random: Random)
      if respect_retry_after && error.is_a?(APIError) && (ms = RetryAfter.parse_ms(error.headers))
        return ms / 1000.0
      end
      return 0.0 if backoff_initial.zero? || backoff_max.zero?

      base = [backoff_initial * (2**retry_index), backoff_max].min
      base - (base * backoff_jitter * random.rand)
    end

    def with(**overrides)
      self.class.new(**to_h, **overrides)
    end

    def to_h
      {
        max_retries:, backoff_initial:, backoff_max:, backoff_jitter:, http_statuses:,
        respect_retry_after:, connection_errors:, timeout_errors:, exceptions:, predicate:, timeout:
      }
    end
  end
end
