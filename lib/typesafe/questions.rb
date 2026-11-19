# frozen_string_literal: true

module TypeSafe
  # Base class for the System One question types. Any question can also be
  # passed as a plain Hash in the API's wire format, e.g.
  # +{ type: "noul", instructions: "Is this spam?" }+.
  class Question
    attr_reader :instructions

    def type
      self.class::TYPE
    end

    # Wire-format hash (string keys). Content values are left as-is so the
    # request builder can resolve embedded images.
    def to_h
      h = { "type" => type }
      h["instructions"] = instructions unless instructions.nil?
      h
    end

    def ==(other)
      other.class == self.class && other.to_h == to_h
    end
    alias eql? ==

    def hash
      to_h.hash
    end
  end

  # A yes/no question or statement. The answer is the probability of yes/true.
  #
  #   TypeSafe::Noul.new("Is this message spam?")
  #   TypeSafe::Noul.new(instructions: "Is this spam?",
  #                      criteria: { yes: "Unsolicited advertising", no: "A real conversation" })
  class Noul < Question
    TYPE = "noul"
    CRITERIA_KEYS = { "true" => "true", "yes" => "true", "false" => "false", "no" => "false" }.freeze

    attr_reader :criteria

    # @param criteria [Hash, nil] +{ yes: ..., no: ... }+ (or +true+/+false+ keys) describing
    #   what counts as a yes and a no.
    #   Each side may be a String, Hash, Array, or Image.
    def initialize(positional_instructions = nil, instructions: positional_instructions, criteria: nil)
      super()
      @instructions = instructions
      @criteria = normalize_criteria(criteria)
    end

    def to_h
      h = super
      h["criteria"] = criteria unless criteria.nil?
      h
    end

    private

    def normalize_criteria(criteria)
      return nil if criteria.nil?
      raise ArgumentError, "Noul criteria must be a Hash with :true and/or :false" unless criteria.is_a?(Hash)

      criteria.each_with_object({}) do |(key, value), out|
        name = CRITERIA_KEYS[key.to_s]
        raise ArgumentError, "Noul criteria keys must be true/false (or yes/no), got #{key.inspect}" unless name

        out[name] = value
      end
    end
  end

  # Selects one option from a set you define. The answer includes the chosen
  # option, a probability for every option, and confidence.
  #
  #   TypeSafe::Choice.new("What is the tone?", criteria: { calm: "Neutral or polite", angry: nil })
  #   TypeSafe::Choice.new("Which department?", criteria: %w[billing support sales])
  class Choice < Question
    TYPE = "choice"
    MAX_OPTIONS = 255

    attr_reader :criteria

    # @param criteria [Hash{String,Symbol=>Object}, Array<String,Symbol>] option names mapped
    #   to descriptions (nil means "interpret by name alone"), or just a list of names.
    def initialize(positional_instructions = nil, criteria:, instructions: positional_instructions)
      super()
      @instructions = instructions
      @criteria = normalize_criteria(criteria)
    end

    def options
      criteria.keys
    end

    def to_h
      super.merge("criteria" => criteria)
    end

    private

    def normalize_criteria(criteria)
      pairs = case criteria
              when Hash then criteria.map { |k, v| [k.to_s, v] }
              when Array then criteria.map { |k| [k.to_s, nil] }
              else raise ArgumentError, "Choice criteria must be a Hash or Array"
              end
      count = pairs.size
      unless count.between?(1, MAX_OPTIONS)
        raise ArgumentError, "Choice needs between 1 and #{MAX_OPTIONS} options, got #{count}"
      end
      raise ArgumentError, "Choice option names must be unique" if pairs.map(&:first).uniq.size != count
      raise ArgumentError, "Choice option names must not be empty" if pairs.any? { |k, _| k.empty? }

      pairs.to_h
    end
  end

  # Rates content against ordered, descriptive levels. The position of each
  # level determines its score, starting at zero.
  #
  #   TypeSafe::Score.new("How urgent is this?", criteria: ["Can wait", "This week", "Today"])
  class Score < Question
    TYPE = "score"
    MAX_LEVELS = 10

    attr_reader :criteria

    # @param criteria [Array] 1 to 10 level descriptions, lowest first.
    def initialize(positional_instructions = nil, criteria:, instructions: positional_instructions)
      super()
      raise ArgumentError, "Score criteria must be an Array" unless criteria.is_a?(Array)
      unless criteria.size.between?(1, MAX_LEVELS)
        raise ArgumentError, "Score needs between 1 and #{MAX_LEVELS} levels, got #{criteria.size}"
      end

      @instructions = instructions
      @criteria = criteria.dup
    end

    def to_h
      super.merge("criteria" => criteria)
    end
  end

  # Locates what the instructions describe in the request's image. Box
  # questions require images to be enabled (the client does this for you).
  #
  #   TypeSafe::Box.new("Locate the red rectangle.")
  class Box < Question
    TYPE = "box"

    def initialize(positional_instructions = nil, instructions: positional_instructions)
      super()
      @instructions = instructions
    end
  end

  # Builder helpers: TypeSafe.noul(...), TypeSafe.choice(...), TypeSafe.score(...), TypeSafe.box(...)
  module QuestionHelpers
    def noul(...) = Noul.new(...)
    def choice(...) = Choice.new(...)
    def score(...) = Score.new(...)
    def box(...) = Box.new(...)
  end
end
