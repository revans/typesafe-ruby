# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  include TestHelpers

  def test_requires_api_key
    assert_raises(TypeSafe::ConfigurationError) { TypeSafe::Client.new }
    assert_raises(TypeSafe::ConfigurationError) { TypeSafe::Client.new(api_key: "has space") }
  end

  def test_env_and_configure_precedence
    ENV["TYPESAFE_API_KEY"] = "env-key"
    ENV["TYPESAFE_DEFAULT_MODEL"] = "jev-env"
    assert_equal "jev-env", TypeSafe::Client.new.model
    TypeSafe.configure { |c| c.model = "jev-config" }
    assert_equal "jev-config", TypeSafe::Client.new.model
    assert_equal "jev-explicit", TypeSafe::Client.new(model: "jev-explicit").model
  ensure
    ENV.delete("TYPESAFE_API_KEY")
    ENV.delete("TYPESAFE_DEFAULT_MODEL")
  end

  def test_system_one_sends_request_and_parses_answers
    answers = {
      "billing" => { "type" => "noul", "noul" => 0.98 },
      "tone" => { "type" => "choice", "choice" => "angry", "confidence" => 0.9,
                  "probabilities" => { "angry" => 0.8, "calm" => 0.2 } },
      "urgency" => { "type" => "score", "score" => 1.7, "confidence" => 0.85,
                     "legend" => { "0" => "low", "1" => "medium", "2" => "high" },
                     "probabilities" => { "0" => 0.1, "1" => 0.1, "2" => 0.8 } }
    }
    stub = stub_request(:post, "#{BASE}/v1/systemone")
           .with(headers: { "Authorization" => "Bearer test-key", "Content-Type" => "application/json",
                            "Accept" => "application/json" })
           .to_return(json(system_one_body(answers), headers: { "x-typesafe-request-id" => "req_1" }))

    result = client.system_one(
      state: { subject: "Duplicate charge", message: "Charged twice!" },
      questions: {
        billing: TypeSafe.noul("Is this about billing?"),
        tone: TypeSafe.choice("Tone?", criteria: %w[angry calm]),
        urgency: TypeSafe.score("Urgency?", criteria: %w[low medium high])
      }
    )

    assert_requested stub
    assert_requested(:post, "#{BASE}/v1/systemone") do |req|
      body = captured_json(req)
      assert_equal "jev-latest", body["model"]
      assert_equal({ "subject" => "Duplicate charge", "message" => "Charged twice!" }, body["state"])
      assert_equal "choice", body["questions"]["tone"]["type"]
      refute req.headers.key?("Typesafe-Danger-Zone-Images")
      true
    end

    assert_equal "jev-1.14", result.model
    assert_equal "req_1", result.request_id
    assert_in_delta 0.98, result[:billing].noul
    assert result[:billing].yes?
    assert_equal "angry", result.choices["tone"].choice
    assert_equal([%w[angry 0.8], %w[calm 0.2]], result[:tone].ranked.map { |k, v| [k, v.to_s] })
    assert_equal 2, result[:urgency].rounded
    assert_equal "high", result[:urgency].label
    assert_equal 2, result[:urgency].most_likely_level
    assert_equal 132, result.usage.total_tokens
    assert_equal %w[billing], result.nouls.keys
  end

  def test_positional_arguments_and_raw_hash_questions
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    result = client.ask("Charged twice", { billing: { type: :noul, instructions: "Billing?" } })
    assert_in_delta 0.98, result["billing"].probability
    assert_requested(:post, "#{BASE}/v1/systemone") do |req|
      captured_json(req)["questions"]["billing"] == { "type" => "noul", "instructions" => "Billing?" }
    end
  end

  def test_large_bodies_are_gzipped
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    client.system_one(state: "x" * 5000, questions: { billing: TypeSafe.noul("?") })
    assert_requested(:post, "#{BASE}/v1/systemone") do |req|
      req.headers["Content-Encoding"] == "gzip" && captured_json(req)["state"] == "x" * 5000
    end
  end

  def test_compression_can_be_disabled
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    client(compression: false).system_one(state: "x" * 5000, questions: { billing: TypeSafe.noul("?") })
    assert_requested(:post, "#{BASE}/v1/systemone") { |req| !req.headers.key?("Content-Encoding") }
  end

  def test_long_context_header
    stub_request(:post, "#{BASE}/v1/systemone")
      .with(headers: { "TypeSafe-Danger-Zone-Long-Context" => "true" })
      .to_return(json(system_one_body))
    client.system_one(state: "s", questions: { billing: TypeSafe.noul("?") }, long_context: true)
  end

  def test_rejects_non_finite_numbers_before_sending
    assert_raises(ArgumentError) { client.system_one(state: { x: Float::NAN }, questions: { a: TypeSafe.noul("?") }) }
    assert_raises(ArgumentError) { client.system_one(state: "s", questions: {}) }
  end

  def test_list_models
    stub_request(:get, "#{BASE}/v1/models").to_return(json(
                                                        { "models" => [{ "name" => "jev-latest",
                                                                         "description" => "General", "release_date" => "2026-09-15" }] }
                                                      ))
    models = client.models.list
    assert_equal ["jev-latest"], models.names
    assert_equal Date.new(2026, 9, 15), models["jev-latest"].released_on
  end

  def test_unknown_answer_types_are_preserved
    stub_request(:post, "#{BASE}/v1/systemone")
      .to_return(json(system_one_body("x" => { "type" => "future", "value" => 1 })))
    result = client.system_one(state: "s", questions: { x: { type: "future" } })
    assert_instance_of TypeSafe::UnknownAnswer, result[:x]
    assert_equal 1, result[:x][:value]
  end

  def test_malformed_success_raises_response_validation_error
    stub_request(:post, "#{BASE}/v1/systemone")
      .to_return(json(system_one_body("tone" => { "type" => "choice", "choice" => "a", "probabilities" => {} })))
    err = assert_raises(TypeSafe::ResponseValidationError) do
      client.system_one(state: "s", questions: { tone: TypeSafe.choice(criteria: %w[a]) })
    end
    assert_equal "answers.tone.confidence", err.field_path
    assert_equal 200, err.status
  end

  def test_extra_headers_cannot_override_auth
    stub_request(:post, "#{BASE}/v1/systemone")
      .with(headers: { "Authorization" => "Bearer test-key", "X-Trace" => "1" })
      .to_return(json(system_one_body))
    client.system_one(state: "s", questions: { billing: TypeSafe.noul("?") },
                      extra_headers: { "Authorization" => "Bearer evil", "X-Trace" => "1" })
  end

  def test_global_client
    TypeSafe.configure { |c| c.api_key = "global" }
    stub_request(:post, "#{BASE}/v1/systemone").with(headers: { "Authorization" => "Bearer global" })
                                               .to_return(json(system_one_body))
    assert_in_delta 0.98, TypeSafe.system_one(state: "s", questions: { billing: TypeSafe.noul("?") })[:billing].noul
  end
end
