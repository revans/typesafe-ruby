# frozen_string_literal: true

module TypeSafe
  # Base class for typed answers. +raw+ always holds the answer exactly as the
  # API returned it, so fields added in future API versions stay reachable.
  class Answer
    attr_reader :name, :raw

    # Builds the right Answer subclass for a raw answer hash.
    def self.build(name, raw, path:)
      Validation.hash!(raw, path)
      klass = TYPES.fetch(raw["type"], UnknownAnswer)
      klass.new(name, raw, path: path)
    end

    def initialize(name, raw, path:)
      @name = name
      @raw = raw.freeze
      @path = path
    end

    def type
      raw["type"]
    end

    def [](key)
      raw[key.to_s]
    end

    def to_h
      raw
    end

    def inspect
      fields = raw.except("type").map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      "#<#{self.class.name} #{name} #{fields}>"
    end

    private

    def number!(key, nullable: false)
      Validation.number!(raw, key, "#{@path}.#{key}", nullable: nullable)
    end

    def prob_hash!(key)
      value = raw[key]
      Validation.hash!(value, "#{@path}.#{key}")
      value.each_key { |k| Validation.number!(value, k, "#{@path}.#{key}.#{k}") }
      value
    end
  end

  # The probability (0..1) that the answer to a yes/no question is yes.
  class NoulAnswer < Answer
    attr_reader :noul

    def initialize(...)
      super
      @noul = number!("noul")
    end

    alias probability noul

    # True when the probability of yes is at least +threshold+.
    def yes?(threshold = 0.5)
      noul >= threshold
    end

    # True when the probability of yes is at most +1 - threshold+.
    def no?(threshold = 0.5)
      noul <= 1 - threshold
    end
  end

  # The selected option, the probability of every option, and confidence.
  class ChoiceAnswer < Answer
    attr_reader :choice, :confidence, :probabilities

    def initialize(...)
      super
      @choice = raw["choice"]
      raise Validation.error("expected a string", "#{@path}.choice") unless @choice.is_a?(String)

      @confidence = number!("confidence")
      @probabilities = prob_hash!("probabilities")
    end

    # Probability of +option+ (String or Symbol), or nil if it was not an option.
    def probability(option = choice)
      probabilities[option.to_s]
    end

    # Options sorted from most to least likely, as [[name, probability], ...].
    def ranked
      probabilities.sort_by { |name, p| [-p, name] }
    end
  end

  # An expected score (probability-weighted average of the levels, so it may
  # fall between integers), the level probabilities, the legend, and confidence.
  class ScoreAnswer < Answer
    attr_reader :score, :confidence, :legend, :probabilities

    def initialize(...)
      super
      @score = number!("score")
      @confidence = number!("confidence")
      @legend = raw["legend"]
      Validation.hash!(@legend, "#{@path}.legend")
      @probabilities = prob_hash!("probabilities")
    end

    # The single most likely level, as an Integer.
    def most_likely_level
      probabilities.max_by { |_, p| p }&.first&.to_i
    end

    # The level nearest the expected score, as an Integer.
    def rounded
      score.round
    end

    # The legend description for +level+ (defaults to the nearest level).
    def label(level = rounded)
      legend[level.to_s]
    end

    def probability(level)
      probabilities[level.to_s]
    end
  end

  # Normalized box edges. Vertical coordinates are fractions of the image
  # height from the top; horizontal are fractions of the width from the left.
  BoxCoordinates = Struct.new(:top, :bottom, :left, :right, keyword_init: true) do
    def width = right - left
    def height = bottom - top
    def area = width * height
    def center = [(left + right) / 2.0, (top + bottom) / 2.0]

    # Pixel coordinates for an image of the given size: { x:, y:, width:, height: }.
    def to_pixels(image_width, image_height)
      x = (left * image_width).round
      y = (top * image_height).round
      {
        x: x, y: y,
        width: (right * image_width).round - x,
        height: (bottom * image_height).round - y
      }
    end
  end

  # Where something is in an image.
  class BoxAnswer < Answer
    attr_reader :box, :confidence

    def initialize(...)
      super
      coords = raw["box"]
      Validation.hash!(coords, "#{@path}.box")
      values = %w[top bottom left right].to_h { |k| [k.to_sym, Validation.number!(coords, k, "#{@path}.box.#{k}")] }
      @box = BoxCoordinates.new(**values).freeze
      @confidence = number!("confidence", nullable: true)
    end
  end

  # An answer type this version of the gem does not know about yet.
  class UnknownAnswer < Answer; end

  class Answer
    TYPES = {
      "noul" => NoulAnswer,
      "choice" => ChoiceAnswer,
      "score" => ScoreAnswer,
      "box" => BoxAnswer
    }.freeze
  end
end
