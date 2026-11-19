# frozen_string_literal: true

require "test_helper"

class ErrorsAndRetriesTest < Minitest::Test
  include TestHelpers

  def ask(api = client)
    api.system_one(state: "s", questions: { billing: TypeSafe.noul("?") })
  end

  def test_status_mapping
    {
      400 => TypeSafe::BadRequestError, 401 => TypeSafe::AuthenticationError,
      403 => TypeSafe::PermissionDeniedError, 404 => TypeSafe::NotFoundError,
      413 => TypeSafe::PayloadTooLargeError, 415 => TypeSafe::UnsupportedMediaTypeError,
      422 => TypeSafe::UnprocessableEntityError
    }.each do |status, klass|
      WebMock.reset!
      stub_request(:post, "#{BASE}/v1/systemone").to_return(json({ "detail" => "nope" }, status: status))
      err = assert_raises(klass) { ask }
      assert_equal status, err.status
      assert_includes err.message, "nope"
    end
  end

  def test_validation_error_details
    detail = [{ "loc" => %w[body state], "msg" => "Field required", "type" => "missing" }]
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json({ "detail" => detail }, status: 422))
    err = assert_raises(TypeSafe::UnprocessableEntityError) { ask }
    assert_equal "missing", err.validation_errors.first["type"]
    assert_includes err.message, "body.state: Field required"
  end

  def test_context_length_error
    stub_request(:post, "#{BASE}/v1/systemone")
      .to_return(json({ "detail" => { "type" => "max_tokens_exceeded" } }, status: 400))
    assert_raises(TypeSafe::ContextLengthExceededError) { ask }
  end

  def test_retries_429_then_succeeds_honoring_retry_after
    stub_request(:post, "#{BASE}/v1/systemone")
      .to_return(json({ "detail" => "slow down" }, status: 429, headers: { "retry-after-ms" => "250" }))
      .then.to_return(json(system_one_body))
    assert_in_delta 0.98, ask[:billing].noul
    assert_equal [0.25], @sleeps
  end

  def test_retries_529_with_backoff_then_raises
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json({ "detail" => "busy" }, status: 529))
    assert_raises(TypeSafe::OverloadedError) { ask }
    assert_requested :post, "#{BASE}/v1/systemone", times: 3
    assert_equal 2, @sleeps.size
    assert(@sleeps.all? { |s| s.between?(0.375, 1.0) })
  end

  def test_no_retry_on_4xx_or_when_disabled
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json({ "detail" => "x" }, status: 400))
    assert_raises(TypeSafe::BadRequestError) { ask }
    assert_requested :post, "#{BASE}/v1/systemone", times: 1

    WebMock.reset!
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json({}, status: 500))
    assert_raises(TypeSafe::InternalServerError) { ask(client(retry_policy: TypeSafe::RetryPolicy.none)) }
    assert_requested :post, "#{BASE}/v1/systemone", times: 1
  end

  def test_timeouts_and_connection_errors
    stub_request(:post, "#{BASE}/v1/systemone").to_timeout
    err = assert_raises(TypeSafe::APITimeoutError) { ask }
    assert_equal 10.0, err.timeout
    assert_requested :post, "#{BASE}/v1/systemone", times: 3

    WebMock.reset!
    stub_request(:post, "#{BASE}/v1/systemone").to_raise(Errno::ECONNREFUSED)
    assert_raises(TypeSafe::APIConnectionError) { ask(client(retry_policy: TypeSafe::RetryPolicy.none)) }
  end

  def test_retry_budget
    stub_request(:post, "#{BASE}/v1/systemone")
      .to_return(json({}, status: 429, headers: { "retry-after" => "60" }))
    assert_raises(TypeSafe::RateLimitError) { ask }
    assert_requested :post, "#{BASE}/v1/systemone", times: 1
  end

  def test_rate_limit_retry_after
    err = TypeSafe::RateLimitError.new(status: 429, headers: { "retry-after" => "2" })
    assert_equal 2000.0, err.retry_after_ms
  end
end
