# frozen_string_literal: true

require "test_helper"

class QuestionsTest < Minitest::Test
  include TestHelpers

  def test_noul_positional_and_keyword
    assert_equal({ "type" => "noul", "instructions" => "Spam?" }, TypeSafe::Noul.new("Spam?").to_h)
    q = TypeSafe::Noul.new(instructions: "Spam?", criteria: { true => "Ads", false => "Real" })
    assert_equal({ "true" => "Ads", "false" => "Real" }, q.to_h["criteria"])
  end

  def test_noul_yes_no_aliases
    q = TypeSafe::Noul.new("Spam?", criteria: { yes: "Ads", no: "Real" })
    assert_equal({ "true" => "Ads", "false" => "Real" }, q.criteria)
  end

  def test_noul_rejects_bad_criteria
    assert_raises(ArgumentError) { TypeSafe::Noul.new("x", criteria: { maybe: "?" }) }
  end

  def test_choice_accepts_array_or_hash
    assert_equal({ "a" => nil, "b" => nil }, TypeSafe::Choice.new(criteria: %i[a b]).criteria)
    assert_equal({ "calm" => "Polite" }, TypeSafe::Choice.new("t", criteria: { calm: "Polite" }).criteria)
  end

  def test_choice_limits
    assert_raises(ArgumentError) { TypeSafe::Choice.new(criteria: []) }
    assert_raises(ArgumentError) { TypeSafe::Choice.new(criteria: (1..256).map(&:to_s)) }
    assert_raises(ArgumentError) { TypeSafe::Choice.new(criteria: ["a", :a]) }
  end

  def test_score_limits
    assert_equal 3, TypeSafe::Score.new("u", criteria: %w[l m h]).criteria.size
    assert_raises(ArgumentError) { TypeSafe::Score.new(criteria: []) }
    assert_raises(ArgumentError) { TypeSafe::Score.new(criteria: (0..10).to_a) }
  end

  def test_box_and_helpers
    assert_equal({ "type" => "box", "instructions" => "Find it" }, TypeSafe.box("Find it").to_h)
    assert_kind_of TypeSafe::Score, TypeSafe.score("x", criteria: [1])
  end
end
