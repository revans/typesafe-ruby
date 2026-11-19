# frozen_string_literal: true

require "json"

module TypeSafe
  # Turns Ruby-friendly System One arguments into a wire-format request:
  # stringifies keys, converts Question objects, swaps embedded Image objects
  # for their references, and gathers the assets that must be uploaded.
  class RequestBuilder
    Built = Struct.new(:payload, :images, :raw_assets, :uses_images, keyword_init: true)

    def initialize(model:, state:, questions:, assets: nil, attached: [])
      @model = model
      @state = state
      @questions = questions
      @assets = assets
      @attached = attached
      @images = {}   # ref => Image
      @strings = []  # every string in the request, to find attached refs
    end

    def build
      raise ArgumentError, "model is required" if @model.nil? || @model.to_s.strip.empty?
      raise ArgumentError, "state is required" if @state.nil?

      payload = {
        "model" => @model.to_s,
        "state" => resolve(@state),
        "questions" => build_questions
      }

      raw_assets = {}
      explicit_assets.each do |ref, asset|
        case asset
        when Image then add_image(ref, asset)
        when Hash then raw_assets[ref] = stringify_keys(asset)
        else raise ArgumentError, "asset #{ref.inspect} must be a TypeSafe::Image or a Hash"
        end
      end
      @attached.each { |image| add_image(image.ref, image) if referenced?(image.ref) }

      has_box = payload["questions"].each_value.any? { |q| q["type"] == Box::TYPE }
      Built.new(
        payload: payload,
        images: @images,
        raw_assets: raw_assets,
        uses_images: has_box || !@images.empty? || !raw_assets.empty?
      )
    end

    private

    def build_questions
      unless @questions.is_a?(Hash) && !@questions.empty?
        raise ArgumentError, "questions must be a non-empty Hash of name => question"
      end

      @questions.each_with_object({}) do |(name, question), out|
        key = name.to_s
        raise ArgumentError, "question names must not be empty" if key.empty?
        raise ArgumentError, "duplicate question name #{key.inspect}" if out.key?(key)

        hash = case question
               when Question then question.to_h
               when Hash then stringify_keys(question)
               else raise ArgumentError, "question #{key.inspect} must be a TypeSafe::Question or a Hash"
               end
        raise ArgumentError, "question #{key.inspect} is missing a type" unless hash["type"]

        out[key] = resolve(hash)
      end
    end

    # Recursively converts content to JSON-ready values.
    def resolve(value)
      case value
      when Image
        add_image(value.ref, value)
        value.ref
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_s] = resolve(v) }
      when Array
        value.map { |v| resolve(v) }
      when String
        @strings << value
        value
      when Symbol
        resolve(value.to_s)
      when Float
        raise ArgumentError, "non-finite number #{value} is not allowed in a request" unless value.finite?

        value
      when Question
        resolve(value.to_h)
      else
        value
      end
    end

    def add_image(ref, image)
      ref = ref.to_s
      existing = @images[ref]
      if existing && !existing.equal?(image) && existing.data != image.data
        raise ArgumentError, "two different images share the reference #{ref.inspect}"
      end

      @images[ref] = image
    end

    def referenced?(ref)
      @strings.any? { |s| s.include?(ref) }
    end

    def explicit_assets
      case @assets
      when nil then {}
      when Image then { @assets.ref => @assets }
      when Array
        @assets.each_with_object({}) do |a, h|
          raise ArgumentError, "assets Array may only contain TypeSafe::Image objects" unless a.is_a?(Image)

          h[a.ref] = a
        end
      when Hash then @assets.transform_keys(&:to_s)
      else raise ArgumentError, "assets must be an Image, an Array of Images, or a Hash of ref => asset"
      end
    end

    def stringify_keys(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys(v) }
      when Array then value.map { |v| stringify_keys(v) }
      else value
      end
    end
  end
end
