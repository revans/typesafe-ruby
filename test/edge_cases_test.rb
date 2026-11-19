# frozen_string_literal: true

require "test_helper"
require "logger"
require "stringio"
require "tmpdir"

# Edge cases and less-travelled branches.
class EdgeCasesTest < Minitest::Test
  include TestHelpers

  def noul_q = { billing: TypeSafe.noul("?") }

  # --- logging -------------------------------------------------------------

  def test_logging_redacts_api_key_and_records_retries
    io = StringIO.new
    stub_request(:post, "#{BASE}/v1/systemone")
      .to_return(json({}, status: 503)).then
      .to_return(json(system_one_body, headers: { "x-typesafe-request-id" => "req_7" }))
    client(logger: Logger.new(io, level: :debug), headers: { "X-Api-Token" => "tok" })
      .system_one(state: "s", questions: noul_q)
    log = io.string
    refute_includes log, "test-key"
    refute_includes log, "tok\""
    assert_includes log, "[REDACTED]"
    assert_includes log, "(retry 1) request_id=req_7"
    assert_includes log, "retrying after InternalServerError"
  end

  def test_log_level_env_creates_logger
    ENV["TYPESAFE_LOG_LEVEL"] = "info"
    assert_equal Logger::INFO, client.logger.level
    ENV["TYPESAFE_LOG_LEVEL"] = "loud"
    assert_raises(TypeSafe::ConfigurationError) { client }
  ensure
    ENV.delete("TYPESAFE_LOG_LEVEL")
  end

  # --- configuration -------------------------------------------------------

  def test_invalid_options
    assert_raises(TypeSafe::ConfigurationError) { client(image_upload: :ftp) }
    assert_raises(TypeSafe::ConfigurationError) { client(compression: :brotli) }
    assert_raises(TypeSafe::ConfigurationError) { client(timeout: 0) }
    assert_raises(TypeSafe::ConfigurationError) { TypeSafe::Client.new(api_key: "naïve") }
  end

  def test_base_url_trailing_slash_and_inspect
    c = client(base_url: "https://example.test/")
    assert_equal "https://example.test", c.base_url
    refute_includes c.inspect, "test-key"
  end

  def test_zstd_without_gem_raises_configuration_error
    skip "zstd-ruby is installed" if Gem::Specification.any? { |s| s.name == "zstd-ruby" }
    assert_raises(TypeSafe::ConfigurationError) do
      client(compression: :zstd).system_one(state: "x" * 2000, questions: noul_q)
    end
  end

  def test_small_bodies_are_not_compressed
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    client.system_one(state: "short", questions: noul_q)
    assert_requested(:post, "#{BASE}/v1/systemone") { |req| !req.headers.key?("Content-Encoding") }
  end

  # --- errors --------------------------------------------------------------

  def test_non_json_error_body
    stub_request(:post, "#{BASE}/v1/systemone")
      .to_return(status: 502, body: "<html>Bad Gateway</html>", headers: { "x-typesafe-request-id" => "r1" })
    err = assert_raises(TypeSafe::InternalServerError) do
      client(retry_policy: TypeSafe::RetryPolicy.none).system_one(state: "s", questions: noul_q)
    end
    assert_equal "<html>Bad Gateway</html>", err.body
    assert_nil err.detail
    assert_equal "r1", err.request_id
    assert_equal "POST https://api.typesafe.ai/v1/systemone", err.endpoint
  end

  def test_non_json_success_body
    stub_request(:post, "#{BASE}/v1/systemone").to_return(status: 200, body: "ok")
    err = assert_raises(TypeSafe::ResponseValidationError) { client.system_one(state: "s", questions: noul_q) }
    assert_equal "$", err.field_path
  end

  def test_unmapped_status
    stub_request(:get, "#{BASE}/v1/models").to_return(json({ "detail" => "teapot" }, status: 418))
    err = assert_raises(TypeSafe::APIError) { client.list_models }
    assert_equal TypeSafe::APIError, err.class
  end

  def test_connection_errors_are_retried
    stub_request(:get, "#{BASE}/v1/models").to_raise(Errno::ECONNRESET).then
                                           .to_return(json({ "models" => [] }))
    assert_equal 0, client.models.list.size
    assert_equal 1, @sleeps.size
  end

  def test_retry_after_http_date
    future = (Time.now + 3).httpdate
    ms = TypeSafe::RetryAfter.parse_ms({ "retry-after" => future })
    assert_operator ms, :>, 1000
    assert_equal 0.0, TypeSafe::RetryAfter.parse_ms({ "retry-after" => (Time.now - 60).httpdate })
    assert_nil TypeSafe::RetryAfter.parse_ms({ "retry-after" => "soon" })
    assert_nil TypeSafe::RetryAfter.parse_ms({})
  end

  # --- retry policy --------------------------------------------------------

  def test_retry_policy_options
    policy = TypeSafe::RetryPolicy.new(max_retries: 1, backoff_initial: 0, connection_errors: false,
                                       exceptions: [KeyError], predicate: ->(e) { e.is_a?(IndexError) })
    refute policy.retryable?(TypeSafe::APIConnectionError.new)
    assert policy.retryable?(TypeSafe::APITimeoutError.new)
    assert policy.retryable?(KeyError.new)
    assert policy.retryable?(IndexError.new)
    refute policy.retryable?(RuntimeError.new)
    assert_equal 0.0, policy.delay_for(3)

    tuned = policy.with(max_retries: 4)
    assert_equal 4, tuned.max_retries
    refute tuned.connection_errors
    assert_raises(ArgumentError) { TypeSafe::RetryPolicy.new(max_retries: -1) }
    assert_raises(ArgumentError) { TypeSafe::RetryPolicy.new(backoff_jitter: 2) }
  end

  def test_backoff_grows_and_caps
    policy = TypeSafe::RetryPolicy.new(backoff_jitter: 0)
    assert_equal([0.5, 1.0, 2.0, 4.0, 5.0], (0..4).map { |i| policy.delay_for(i) })
  end

  def test_retry_after_ignored_when_disabled
    policy = TypeSafe::RetryPolicy.new(respect_retry_after: false, backoff_jitter: 0)
    err = TypeSafe::RateLimitError.new(status: 429, headers: { "retry-after" => "9" })
    assert_equal 0.5, policy.delay_for(0, err)
  end

  # --- images --------------------------------------------------------------

  def test_image_constructors
    Dir.mktmpdir do |dir|
      path = File.join(dir, "shot.png")
      File.binwrite(path, PNG)
      img = TypeSafe::Image.from_path(path)
      assert_equal ["png", "shot.png", "image/png"], [img.format, img.filename, img.content_type]
      assert_equal img.data, File.open(path, "rb") { |f| TypeSafe::Image.from_io(f) }.data
    end
    b64 = TypeSafe::Image.from_base64("data:image/jpeg;base64,#{Base64.strict_encode64(JPEG)}")
    assert_equal JPEG, b64.data
    assert_equal "jpg", b64.format
    assert_match(/format=jpg bytes=36/, b64.inspect)
    assert_raises(ArgumentError) { TypeSafe::Image.from_bytes("") }
    assert_raises(ArgumentError) { TypeSafe::Image.from_bytes(PNG, format: :gif) }
  end

  def test_raw_hash_and_single_image_assets
    img = TypeSafe::Image.from_bytes(PNG, ref: "one")
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    client.system_one(state: "see one and two", questions: noul_q,
                      assets: { "two" => { type: "image", format: "png", data_base64: "AAAA" }, "one" => img })
    client(image_upload: :base64).system_one(state: "see one", questions: noul_q, assets: img)
    requests = WebMock::RequestRegistry.instance.requested_signatures.hash.keys
    multipart = requests.find { |r| r.headers["Content-Type"].start_with?("multipart") }
    assert_includes multipart.body, %("two":{"type":"image","format":"png","data_base64":"AAAA"})
    assert_includes multipart.body, %("one":{"type":"image","format":"png","part":"image-1"})
  end

  def test_raw_assets_without_image_objects_use_json
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    client.system_one(state: "ref", questions: noul_q,
                      assets: { ref: { type: "image", format: "png", data_base64: "A" } })
    assert_requested(:post, "#{BASE}/v1/systemone") do |req|
      req.headers["Content-Type"] == "application/json" && captured_json(req)["assets"]["ref"]["data_base64"] == "A" &&
        req.headers["Typesafe-Danger-Zone-Images"] == "true"
    end
  end

  def test_request_builder_rejections
    a = TypeSafe::Image.from_bytes(PNG, ref: "same")
    b = TypeSafe::Image.from_bytes(JPEG, ref: "same")
    assert_raises(ArgumentError) { client.system_one(state: [a, b], questions: noul_q) }
    assert_raises(ArgumentError) { client.system_one(state: "s", questions: noul_q, assets: "nope") }
    assert_raises(ArgumentError) { client.system_one(state: "s", questions: noul_q, assets: ["nope"]) }
    assert_raises(ArgumentError) { client.system_one(state: "s", questions: noul_q, assets: { x: 1 }) }
    assert_raises(ArgumentError) { client.system_one(state: "s", questions: { a: "Is it?" }) }
    assert_raises(ArgumentError) { client.system_one(state: "s", questions: { a: { instructions: "?" } }) }
    assert_raises(ArgumentError) do
      client.system_one(state: "s", questions: { a: TypeSafe.noul("?"), "a" => TypeSafe.noul("?") })
    end
    assert_raises(ArgumentError) { client.system_one(state: "s", questions: { "" => TypeSafe.noul("?") }) }
    assert_raises(ArgumentError) { client.system_one(state: nil, questions: noul_q) }
    assert_raises(ArgumentError) { client.system_one(questions: noul_q) }
    assert_raises(ArgumentError) { client.system_one(state: "s") }
    assert_raises(ArgumentError) { client.system_one(state: "s", questions: noul_q, model: " ") }
    assert_raises(ArgumentError) { client.with_assets("not an image") { nil } }
  end

  def test_content_conversion
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    client.system_one(state: { tags: [:a, 1, 2.5, nil, true], nested: TypeSafe.noul("q") },
                      questions: { billing: { type: "noul", criteria: { true => ["x", { y: :z }] } } })
    assert_requested(:post, "#{BASE}/v1/systemone") do |req|
      body = captured_json(req)
      body["state"] == { "tags" => ["a", 1, 2.5, nil, true],
                         "nested" => { "type" => "noul", "instructions" => "q" } } &&
        body["questions"]["billing"]["criteria"] == { "true" => ["x", { "y" => "z" }] }
    end
  end

  def test_with_assets_nests_and_restores
    a = TypeSafe::Image.from_bytes(PNG, ref: "ref-a")
    b = TypeSafe::Image.from_bytes(PNG, ref: "ref-b")
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    c = client(image_upload: :base64)
    c.with_assets(a) do
      c.with_assets(b) { c.system_one(state: "#{a} #{b}", questions: noul_q) }
      c.system_one(state: "#{a} #{b}", questions: noul_q)
    end
    c.system_one(state: "#{a} #{b}", questions: noul_q)
    bodies = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { |r| JSON.parse(r.body) }
    assert_equal [%w[ref-a ref-b], %w[ref-a], []].sort, bodies.map { |bd| (bd["assets"] || {}).keys.sort }.sort
  end

  # --- answers & responses -------------------------------------------------

  def test_answer_helpers
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body(
                                                                 "n" => { "type" => "noul", "noul" => 0.1 },
                                                                 "c" => { "type" => "choice", "choice" => "a", "confidence" => 0.6,
                                                                          "probabilities" => { "a" => 0.6, "b" => 0.4 } },
                                                                 "s" => { "type" => "score", "score" => 0.4, "confidence" => 0.7, "legend" => { "0" => "lo", "1" => "hi" },
                                                                          "probabilities" => { "0" => 0.6, "1" => 0.4 } }
                                                               )))
    r = client.system_one(state: "s", questions: { n: { type: "noul" }, c: { type: "choice" }, s: { type: "score" } })
    assert r[:n].no?
    refute r[:n].yes?
    assert_equal "noul", r[:n].type
    assert_equal({ "type" => "noul", "noul" => 0.1 }, r[:n].to_h)
    assert_match(/NoulAnswer n noul=0.1/, r[:n].inspect)
    assert_in_delta 0.4, r[:c].probability(:b)
    assert_in_delta 0.6, r[:c].probability
    assert_nil r[:c].probability(:zzz)
    assert_in_delta 0.4, r[:s].probability(1)
    assert_equal "hi", r[:s].label(1)
    assert_equal "lo", r[:s].label
    assert_equal %w[n c s], r.map(&:first)
    assert_equal %w[s], r.scores.keys
    assert_empty r.boxes
    assert_raises(KeyError) { r.fetch(:missing) }
    assert_nil r[:missing]
    assert_equal "jev-1.14", r.to_h["model"]
    assert_match(/answers=\["n", "c", "s"\]/, r.inspect)
  end

  def test_response_validation_paths
    {
      { "answers" => {}, "usage" => {} } => "model",
      { "model" => "m", "answers" => [], "usage" => {} } => "answers",
      { "model" => "m", "answers" => { "a" => 1 }, "usage" => {} } => "answers.a",
      { "model" => "m", "answers" => {}, "usage" => { "input_tokens" => 1.5 } } => "usage.input_tokens",
      { "model" => "m", "answers" => { "b" => { "type" => "box", "box" => { "top" => 0 }, "confidence" => 1 } },
        "usage" => {} } => "answers.b.box.bottom",
      { "model" => "m", "answers" => { "c" => { "type" => "choice", "choice" => 1 } },
        "usage" => {} } => "answers.c.choice",
      { "model" => "m", "answers" => { "s" => { "type" => "score", "score" => 1, "confidence" => 1, "legend" => [] } },
        "usage" => {} } => "answers.s.legend",
      { "model" => "m", "answers" => { "c" => { "type" => "choice", "choice" => "x", "confidence" => 1,
                                                "probabilities" => { "x" => "high" } } }, "usage" => {} } =>
        "answers.c.probabilities.x"
    }.each do |body, path|
      WebMock.reset!
      stub_request(:post, "#{BASE}/v1/systemone").to_return(json(body))
      err = assert_raises(TypeSafe::ResponseValidationError) { client.system_one(state: "s", questions: noul_q) }
      assert_equal path, err.field_path
    end
  end

  def test_model_list_helpers_and_validation
    stub_request(:get, "#{BASE}/v1/models").to_return(json(
                                                        { "models" => [{ "name" => "jev", "description" => "d",
                                                                         "release_date" => "not a date" }] },
                                                        headers: { "x-typesafe-request-id" => "m1" }
                                                      ))
    list = TypeSafe.tap { |t| t.configure { |c| c.api_key = "k" } }.models.list
    assert_equal "m1", list.request_id
    assert_nil list.first.released_on
    assert_equal "jev", list.first.to_s
    assert_equal "d", list.to_h["models"][0]["description"]
    assert_match(/ModelCard jev/, list.first.inspect)

    WebMock.reset!
    stub_request(:get, "#{BASE}/v1/models").to_return(json({ "models" => [{ "name" => "jev" }] }))
    err = assert_raises(TypeSafe::ResponseValidationError) { client.list_models }
    assert_equal "models.0.description", err.field_path
  end

  def test_question_equality
    assert_equal TypeSafe.noul("a"), TypeSafe::Noul.new(instructions: "a")
    refute_equal TypeSafe.noul("a"), TypeSafe.box("a")
    assert_equal 1, [TypeSafe.noul("a"), TypeSafe.noul("a")].uniq.size
    assert_equal %w[x y], TypeSafe.choice(criteria: %w[x y]).options
    assert_raises(ArgumentError) { TypeSafe.choice(criteria: "x") }
    assert_raises(ArgumentError) { TypeSafe.choice(criteria: [""]) }
    assert_raises(ArgumentError) { TypeSafe.score(criteria: "x") }
    assert_raises(ArgumentError) { TypeSafe.noul("x", criteria: "yes") }
  end

  def test_box_coordinates_math
    box = TypeSafe::BoxCoordinates.new(top: 0.0, bottom: 0.5, left: 0.0, right: 0.5)
    assert_in_delta 0.25, box.area
    assert_equal [0.25, 0.25], box.center
  end
end
