# frozen_string_literal: true

# Usage: TYPESAFE_API_KEY=... ruby -Ilib examples/triage.rb
require "typesafe"

client = TypeSafe::Client.new

puts "Models: #{client.models.list.names.join(", ")}"

result = client.system_one(
  state: { subject: "Duplicate charge", message: "I was charged twice this month. Please refund ASAP!" },
  questions: {
    billing: TypeSafe.noul("Is this message about billing?"),
    tone: TypeSafe.choice("What is the tone of this message?",
                          criteria: { calm: "Neutral or polite", angry: "Upset or hostile", excited: "Enthusiastic" }),
    urgency: TypeSafe.score("How urgent is this message?",
                            criteria: ["Can wait", "Needs attention this week", "Needs attention today"])
  }
)

puts "billing: #{result[:billing].noul.round(3)}"
puts "tone:    #{result[:tone].choice} (confidence #{result[:tone].confidence.round(2)})"
puts "urgency: #{result[:urgency].score.round(2)} -> #{result[:urgency].label}"
puts "model:   #{result.model}, tokens: #{result.usage.to_h}"
