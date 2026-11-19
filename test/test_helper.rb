# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "typesafe"
require "minitest/autorun"
require "webmock/minitest"

WebMock.disable_net_connect!

module TestHelpers
  BASE = "https://api.typesafe.ai"
  PNG = "\x89PNG\r\n\x1A\n".b + ("\x00".b * 32)
  JPEG = "\xFF\xD8\xFF\xE0".b + ("\x00".b * 32)

  def setup
    super
    TypeSafe.reset_configuration!
    %w[TYPESAFE_API_KEY TYPESAFE_BASE_URL TYPESAFE_DEFAULT_MODEL TYPESAFE_LOG_LEVEL].each { |k| ENV.delete(k) }
  end

  def client(**)
    c = TypeSafe::Client.new(api_key: "test-key", **)
    c.sleeper = ->(s) { (@sleeps ||= []) << s }
    c
  end

  def json(body, status: 200, headers: {})
    { status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  def system_one_body(answers = { "billing" => { "type" => "noul", "noul" => 0.98 } })
    { "model" => "jev-1.14", "answers" => answers, "usage" => { "input_tokens" => 120, "output_tokens" => 12 } }
  end

  def captured_json(request)
    body = request.body
    body = Zlib.gunzip(body) if request.headers["Content-Encoding"] == "gzip"
    JSON.parse(body)
  end
end
