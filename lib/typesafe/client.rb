# frozen_string_literal: true

require "logger"

module TypeSafe
  # Client for the TypeSafe API.
  #
  #   client = TypeSafe::Client.new # reads TYPESAFE_API_KEY
  #   result = client.system_one(
  #     state: "I was charged twice. Please help.",
  #     questions: {
  #       billing: TypeSafe::Noul.new("Is this about billing?"),
  #       tone: TypeSafe::Choice.new("What is the tone?", criteria: %w[calm angry])
  #     }
  #   )
  #   result[:billing].noul         # => 0.98
  #   result[:tone].choice          # => "angry"
  #
  # Clients are thread-safe and can be shared.
  class Client
    IMAGES_HEADER = "TypeSafe-Danger-Zone-Images"
    LONG_CONTEXT_HEADER = "TypeSafe-Danger-Zone-Long-Context"
    PROTECTED_HEADERS = %w[authorization user-agent accept content-type content-encoding].freeze
    NOT_GIVEN = Object.new.freeze
    private_constant :NOT_GIVEN

    attr_reader :base_url, :model, :timeout, :retry_policy, :compression, :image_upload,
                :headers, :logger, :images, :long_context

    # Explicit options win over TypeSafe.configure values, which win over
    # environment variables, which win over defaults.
    #
    # @param api_key [String] defaults to ENV["TYPESAFE_API_KEY"]
    # @param base_url [String] defaults to ENV["TYPESAFE_BASE_URL"] or https://api.typesafe.ai
    # @param model [String] default model; ENV["TYPESAFE_DEFAULT_MODEL"] or "jev-latest"
    # @param timeout [Numeric] seconds for each HTTP operation (connect/read/write); default 10
    # @param retry_policy [RetryPolicy]
    # @param headers [Hash] extra headers sent on every request
    # @param compression [:gzip, :zstd, false] compress JSON bodies of 1 KiB or more (default :gzip)
    # @param image_upload [:multipart, :base64] how images are sent (default :multipart)
    # @param images [Boolean, nil] true always sends TypeSafe-Danger-Zone-Images; nil (default)
    #   sends it automatically when a request has images or Box questions; false never does
    # @param long_context [Boolean] send TypeSafe-Danger-Zone-Long-Context on every request
    # @param logger [Logger] defaults to a $stderr logger when ENV["TYPESAFE_LOG_LEVEL"] is set
    def initialize(api_key: nil, base_url: nil, model: nil, timeout: nil, retry_policy: nil, headers: nil,
                   compression: NOT_GIVEN, image_upload: nil, images: NOT_GIVEN, long_context: nil, logger: nil)
      config = TypeSafe.configuration
      @api_key = validate_api_key(first_present(api_key, config.api_key, env(API_KEY_ENV)))
      @base_url = first_present(base_url, config.base_url, env(BASE_URL_ENV), DEFAULT_BASE_URL).to_s.chomp("/")
      @model = first_present(model, config.model, env(DEFAULT_MODEL_ENV), DEFAULT_MODEL).to_s
      @timeout = Float(timeout || config.timeout || DEFAULT_TIMEOUT)
      raise ConfigurationError, "timeout must be positive" unless @timeout.positive?

      @retry_policy = retry_policy || config.retry_policy || RetryPolicy.new
      @headers = (config.headers || {}).merge(headers || {}).transform_keys(&:to_s).freeze
      @compression = compression.equal?(NOT_GIVEN) ? config.compression : compression
      validate_compression(@compression)
      @image_upload = (image_upload || config.image_upload || :multipart).to_sym
      unless %i[multipart base64].include?(@image_upload)
        raise ConfigurationError, "image_upload must be :multipart or :base64"
      end

      @images = images.equal?(NOT_GIVEN) ? config.images : images
      @long_context = long_context.nil? ? config.long_context : long_context
      @logger = logger || config.logger || default_logger
      @sleeper = ->(seconds) { sleep(seconds) }
    end

    # Asks one or more questions about +state+ in a single request.
    #
    # @param state [String, Hash, Array] the content every question refers to;
    #   may contain TypeSafe::Image objects anywhere
    # @param questions [Hash{String,Symbol=>Question,Hash}] named questions
    # @param model [String] overrides the client's model
    # @param assets [Image, Array<Image>, Hash{String=>Image,Hash}] images referenced by
    #   placeholder inside strings (embedded Image objects are found automatically)
    # @param images [Boolean, nil] force the images header on/off for this call
    # @param long_context [Boolean, nil] send the long-context header for this call
    # @param timeout [Numeric] per-operation timeout override for this call
    # @param retry_policy [RetryPolicy] retry override for this call
    # @param extra_headers [Hash] extra headers for this call
    # @return [SystemOneResponse]
    def system_one(positional_state = NOT_GIVEN, positional_questions = NOT_GIVEN,
                   state: positional_state, questions: positional_questions, model: nil, assets: nil,
                   images: nil, long_context: nil, timeout: nil, retry_policy: nil, extra_headers: nil)
      raise ArgumentError, "state is required" if state.equal?(NOT_GIVEN)
      raise ArgumentError, "questions is required" if questions.equal?(NOT_GIVEN)

      built = RequestBuilder.new(
        model: model || @model, state: state, questions: questions,
        assets: assets, attached: attached_assets
      ).build

      body = encode(built)
      call_headers = {}
      call_headers[IMAGES_HEADER] = "true" if images_enabled?(images, built.uses_images)
      call_headers[LONG_CONTEXT_HEADER] = "true" if long_context.nil? ? @long_context : long_context

      request(:post, "/v1/systemone", body: body, extra_headers: call_headers.merge(extra_headers || {}),
                                      timeout: timeout, retry_policy: retry_policy) do |raw, headers|
        SystemOneResponse.new(raw, headers: headers)
      end
    end
    alias ask system_one

    # The Models resource: +client.models.list+.
    def models
      @models ||= Resources::Models.new(self)
    end

    # Shorthand for +models.list+.
    def list_models(**)
      models.list(**)
    end

    # Within the block, images whose reference appears in a request's strings
    # are uploaded with that request (others are not sent).
    #
    #   photo = TypeSafe::Image.from_path("item.jpg")
    #   client.with_assets(photo) do
    #     client.system_one(state: "Product photo: #{photo}", questions: { damaged: TypeSafe::Noul.new("Damaged?") })
    #   end
    def with_assets(*images)
      images = images.flatten
      bad = images.grep_v(Image)
      raise ArgumentError, "with_assets only accepts TypeSafe::Image objects" unless bad.empty?

      key = attached_key
      previous = Thread.current[key]
      Thread.current[key] = (previous || []) + images
      yield self
    ensure
      Thread.current[key] = previous if key
    end

    # Performs a raw API request. Without a block, returns
    # [parsed_json, response_headers]; with a block, returns the block's value
    # (the block receives parsed_json and response_headers). Useful for
    # endpoints this gem does not wrap yet.
    #
    # @param body [Hash, HTTP::EncodedBody, nil]
    def request(method, path, body: nil, extra_headers: nil, timeout: nil, retry_policy: nil, &parser)
      body = HTTP.encode_json(body, compression: @compression) if body.is_a?(Hash)
      policy = retry_policy || @retry_policy
      url = "#{@base_url}#{path}"
      headers = build_headers(body, extra_headers)
      op_timeout = timeout ? Float(timeout) : @timeout

      with_retries(policy) do |attempt|
        perform_once(method, url, headers, body, op_timeout, attempt, parser)
      end
    end

    def inspect
      "#<#{self.class.name} base_url=#{base_url.inspect} model=#{model.inspect}>"
    end

    # For tests: replace the sleep function used between retries.
    attr_writer :sleeper

    private

    def perform_once(method, url, headers, body, timeout, attempt, parser)
      started = monotonic
      log_debug { "→ #{method.upcase} #{url} headers=#{HTTP.redact(headers)} body=#{body&.description}" }
      response = HTTP.perform(method: method, url: url, headers: headers, body: body&.bytes, timeout: timeout)
      elapsed = ((monotonic - started) * 1000).round
      @logger&.info(
        "TypeSafe #{method.upcase} #{url} #{response.status} in #{elapsed}ms" \
        "#{" (retry #{attempt})" if attempt.positive?} request_id=#{response.headers["x-typesafe-request-id"]}"
      )
      log_debug { "← #{response.status} headers=#{HTTP.redact(response.headers)} body=#{response.body}" }

      parsed = HTTP.parse_body(response)
      unless (200..299).cover?(response.status)
        raise ErrorMapper.build(status: response.status, body: parsed, headers: response.headers,
                                endpoint: HTTP.endpoint(method, URI(url)))
      end
      raise_invalid_response("response body is not JSON", "$", response, parsed, method, url) unless parsed.is_a?(Hash)

      return [parsed, response.headers] unless parser

      begin
        parser.call(parsed, response.headers)
      rescue Validation::Failure => e
        raise_invalid_response(e.message, e.field_path, response, parsed, method, url)
      end
    end

    def with_retries(policy)
      started = monotonic
      attempt = 0
      begin
        yield attempt
      rescue StandardError => e
        raise unless attempt < policy.max_retries && policy.retryable?(e)

        delay = policy.delay_for(attempt, e)
        raise if policy.timeout && (monotonic - started + delay) > policy.timeout

        @logger&.warn("TypeSafe retrying after #{e.class.name.split("::").last} in #{delay.round(3)}s " \
                      "(retry #{attempt + 1}/#{policy.max_retries})")
        @sleeper.call(delay) if delay.positive?
        attempt += 1
        retry
      end
    end

    def raise_invalid_response(message, field_path, response, parsed, method, url)
      raise ResponseValidationError.new(
        message, field_path: field_path, status: response.status, body: parsed,
                 headers: response.headers, endpoint: HTTP.endpoint(method, URI(url))
      )
    end

    def encode(built)
      if built.images.empty?
        payload = built.payload
        payload = payload.merge("assets" => built.raw_assets) unless built.raw_assets.empty?
        return HTTP.encode_json(payload, compression: @compression)
      end

      if @image_upload == :base64
        assets = built.images.transform_values(&:to_base64_asset).merge(built.raw_assets)
        return HTTP.encode_json(built.payload.merge("assets" => assets), compression: @compression)
      end

      parts = {}
      assets = {}
      built.images.each_with_index do |(ref, image), index|
        name = "image-#{index + 1}"
        parts[name] = image
        assets[ref] = image.to_part_asset(name)
      end
      HTTP.encode_multipart(built.payload.merge("assets" => assets.merge(built.raw_assets)), parts)
    end

    def build_headers(body, extra_headers)
      merged = @headers.merge((extra_headers || {}).transform_keys(&:to_s))
      merged = merged.reject { |k, _| PROTECTED_HEADERS.include?(k.downcase) }
      merged["Authorization"] = "Bearer #{@api_key}"
      merged["Accept"] = "application/json"
      merged["User-Agent"] = USER_AGENT
      if body
        merged["Content-Type"] = body.content_type
        merged["Content-Encoding"] = body.content_encoding if body.content_encoding
      end
      merged
    end

    def images_enabled?(per_call, uses_images)
      return per_call unless per_call.nil?
      return @images unless @images.nil?

      uses_images
    end

    def attached_key
      @attached_key ||= :"typesafe_attached_assets_#{object_id}"
    end

    def attached_assets
      Thread.current[attached_key] || []
    end

    def validate_api_key(key)
      key = key&.to_s&.strip
      if key.nil? || key.empty?
        raise ConfigurationError,
              "Missing API key. Pass api_key:, call TypeSafe.configure, or set #{API_KEY_ENV}."
      end
      raise ConfigurationError, "API key must not contain whitespace" if key.match?(/\s/)
      raise ConfigurationError, "API key must be printable ASCII" unless key.match?(/\A[\x21-\x7E]+\z/)

      key
    end

    def validate_compression(value)
      return if [:gzip, :zstd, false, nil].include?(value)

      raise ConfigurationError, "compression must be :gzip, :zstd, or false"
    end

    def default_logger
      level = env(LOG_LEVEL_ENV)
      return nil unless level

      Logger.new($stderr, level: level.downcase, progname: "typesafe")
    rescue ArgumentError
      raise ConfigurationError, "invalid #{LOG_LEVEL_ENV}: #{level.inspect}"
    end

    def log_debug
      @logger.debug(yield) if @logger&.debug?
    end

    def first_present(*values)
      values.find { |v| !v.nil? && !(v.respond_to?(:empty?) && v.to_s.strip.empty?) }
    end

    def env(name)
      value = ENV.fetch(name, nil)
      value.nil? || value.strip.empty? ? nil : value.strip
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
