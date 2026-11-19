# frozen_string_literal: true

require "date"

module TypeSafe
  # A model or alias available to the authenticated account.
  class ModelCard
    attr_reader :name, :description, :release_date, :raw

    def initialize(raw, path:)
      Validation.hash!(raw, path)
      @raw = raw.freeze
      @name = Validation.string!(raw, "name", "#{path}.name")
      @description = Validation.string!(raw, "description", "#{path}.description")
      @release_date = Validation.string!(raw, "release_date", "#{path}.release_date")
    end

    # The release date as a Date, or nil if it cannot be parsed.
    def released_on
      Date.iso8601(release_date)
    rescue Date::Error
      nil
    end

    def to_s = name
    def to_h = raw

    def inspect
      "#<#{self.class.name} #{name} released=#{release_date}>"
    end
  end

  # The models and aliases returned by GET /v1/models.
  class ModelList
    include Enumerable

    attr_reader :models, :headers, :raw

    def initialize(raw, headers: {})
      Validation.hash!(raw, "$")
      @raw = raw.freeze
      @headers = headers.freeze
      list = Validation.array!(raw["models"], "models")
      @models = list.each_with_index.map { |m, i| ModelCard.new(m, path: "models.#{i}") }.freeze
    end

    def each(&)
      models.each(&)
    end

    def names
      models.map(&:name)
    end

    def [](name)
      models.find { |m| m.name == name.to_s }
    end

    def size = models.size
    def to_h = raw

    def request_id
      headers["x-typesafe-request-id"]
    end
  end
end
