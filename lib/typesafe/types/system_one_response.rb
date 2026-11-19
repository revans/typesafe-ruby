# frozen_string_literal: true

module TypeSafe
  # Token usage for a request. Output tokens are currently free.
  Usage = Struct.new(:input_tokens, :output_tokens, keyword_init: true) do
    def total_tokens = input_tokens + output_tokens
  end

  # The result of a System One request: answers keyed by question name, the
  # model that answered, and token usage.
  #
  #   result = client.system_one(...)
  #   result[:billing].noul           # => 0.98
  #   result.choices["tone"].choice   # => "angry"
  #   result.usage.input_tokens       # => 120
  class SystemOneResponse
    include Enumerable

    attr_reader :model, :answers, :usage, :headers, :raw

    def initialize(raw, headers: {})
      Validation.hash!(raw, "$")
      @raw = raw.freeze
      @headers = headers.freeze
      @model = Validation.string!(raw, "model", "model")
      answers = Validation.hash!(raw["answers"], "answers")
      @answers = answers.to_h { |name, answer| [name, Answer.build(name, answer, path: "answers.#{name}")] }.freeze
      usage = Validation.hash!(raw["usage"], "usage")
      @usage = Usage.new(
        input_tokens: Validation.integer!(usage, "input_tokens", "usage.input_tokens"),
        output_tokens: Validation.integer!(usage, "output_tokens", "usage.output_tokens")
      ).freeze
    end

    # The answer for question +name+ (String or Symbol), or nil.
    def [](name)
      answers[name.to_s]
    end

    # Like #[] but raises KeyError for an unknown name.
    def fetch(name)
      answers.fetch(name.to_s)
    end

    def each(&)
      answers.each(&)
    end

    def nouls = of_type(NoulAnswer)
    def choices = of_type(ChoiceAnswer)
    def scores = of_type(ScoreAnswer)
    def boxes = of_type(BoxAnswer)

    # The +x-typesafe-request-id+ header, for support requests.
    def request_id
      headers["x-typesafe-request-id"]
    end

    def to_h
      raw
    end

    def inspect
      "#<#{self.class.name} model=#{model.inspect} answers=#{answers.keys.inspect} usage=#{usage.to_h}>"
    end

    private

    def of_type(klass)
      answers.select { |_, answer| answer.is_a?(klass) }
    end
  end
end
