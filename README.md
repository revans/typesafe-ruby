# typesafe (Ruby)

A Ruby client for [TypeSafe's](https://docs.typesafe.ai/introduction) System One API and its Jev models. You send state and typed questions, and you get back structured, calibrated answers your code can act on.

The gem covers the whole public API:

| Endpoint | Ruby |
| - | - |
| `POST /v1/systemone` | `client.system_one(state:, questions:, ...)` (alias `ask`) |
| `GET /v1/models` | `client.models.list` (alias `list_models`) |

It also supports all four question types (Noul, Choice, Score, Box), images (multipart or base64), the danger-zone headers, gzip/zstd request compression, retries with backoff and `Retry-After`, typed errors, response validation, and logging. It has no HTTP-library dependencies: it uses `Net::HTTP` from the standard library.

## Install

```ruby
# Gemfile
gem "typesafe", path: "path/to/typesafe-ruby" # or git: "..."
```

Requires Ruby 3.2 or later.

## Quick start

```ruby
require "typesafe"

client = TypeSafe::Client.new # reads ENV["TYPESAFE_API_KEY"]

result = client.system_one(
  state: { subject: "Duplicate charge", message: "I was charged twice. Please help ASAP." },
  questions: {
    billing: TypeSafe::Noul.new("Is this about billing?"),
    tone:    TypeSafe::Choice.new("What is the tone?", criteria: { calm: "Neutral or polite", angry: "Upset or hostile" }),
    urgency: TypeSafe::Score.new("How urgent is this?", criteria: ["Can wait", "This week", "Today"])
  }
)

result[:billing].noul            # => 0.98   probability of "yes"
result[:billing].yes?(0.9)       # => true
result[:tone].choice             # => "angry"
result[:tone].confidence         # => 0.9
result[:tone].probabilities      # => {"angry"=>0.8, "calm"=>0.2}
result[:urgency].score           # => 1.7    expected value across levels
result[:urgency].label           # => "Today" (legend entry for the nearest level)
result.usage.input_tokens        # => 120
result.model                     # => "jev-1.14"
result.request_id                # => "..."   for support requests
```

Shortcuts: `TypeSafe.noul`, `TypeSafe.choice`, `TypeSafe.score`, and `TypeSafe.box` build questions. You can also pass questions as plain hashes in the wire format, such as `{ type: "noul", instructions: "..." }`.

## Rails credentials

In a Rails app the gem reads its settings from encrypted credentials automatically. Run `bin/rails credentials:edit` (or `bin/rails credentials:edit --environment production`) and add:

```yaml
typesafe:
  api_key: ts_live_...
  model: jev-latest          # optional
  base_url: https://...      # optional
```

A flat `typesafe_api_key: ts_live_...` also works. You don't need an initializer:

```ruby
TypeSafe.system_one(state: "...", questions: { ... })   # or TypeSafe::Client.new
```

The gem loads credentials before `config/initializers` run, so anything you set with `TypeSafe.configure` in an initializer overrides them. Credentials also take precedence over the `TYPESAFE_*` environment variables.

## Configuration

Settings are resolved in this order: explicit `Client.new` option, then `TypeSafe.configure` (or Rails credentials), then environment variable, then the default.

```ruby
TypeSafe.configure do |c|
  c.api_key = Rails.application.credentials.typesafe_api_key
  c.model = "jev-latest"
  c.timeout = 15                                   # seconds for each HTTP operation (default 10)
  c.retry_policy = TypeSafe::RetryPolicy.new(max_retries: 4)
  c.logger = Rails.logger
end

TypeSafe.system_one(state: "...", questions: { ... })   # uses a shared default client
```

| Option | Env var | Default |
| - | - | - |
| `api_key` | `TYPESAFE_API_KEY` | (required) |
| `base_url` | `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` |
| `model` | `TYPESAFE_DEFAULT_MODEL` | `jev-latest` |
| `logger` | `TYPESAFE_LOG_LEVEL` (creates a `$stderr` logger) | none |
| `timeout` | | `10.0` |
| `compression` | | `:gzip` (bodies of 1 KiB or more; `:zstd` needs the `zstd-ruby` gem; `false` turns it off) |
| `image_upload` | | `:multipart` (or `:base64`) |
| `images` | | `nil`: send the images header automatically when needed |
| `long_context` | | `false` |
| `headers` | | `{}` |

Clients are thread-safe and can be shared.

## Question types

```ruby
# Noul: yes/no question, answered with P(yes)
TypeSafe::Noul.new("Is this spam?", criteria: { yes: "Unsolicited advertising", no: "A real conversation" })

# Choice: pick one option (1 to 255). Pass a Hash of name => description (nil means the name alone), or an Array of names.
TypeSafe::Choice.new("Which team?", criteria: %w[billing support sales])

# Score: ordered rubric (1 to 10 levels). Each level's position is its score, starting at 0.
TypeSafe::Score.new("Severity?", criteria: ["Cosmetic", "Degraded", "Outage"])

# Box: locate something in an image
TypeSafe::Box.new("Locate the damaged area.")
```

`instructions`, `criteria` values, and `state` can be strings, hashes, or arrays (structured JSON). See [Advanced: structure](https://docs.typesafe.ai/primitives/advanced).

### Answers

| Class | Fields | Helpers |
| - | - | - |
| `NoulAnswer` | `noul` (alias `probability`) | `yes?(t = 0.5)`, `no?(t = 0.5)` |
| `ChoiceAnswer` | `choice`, `confidence`, `probabilities` | `probability(opt)`, `ranked` |
| `ScoreAnswer` | `score`, `confidence`, `legend`, `probabilities` | `rounded`, `most_likely_level`, `label(level)`, `probability(level)` |
| `BoxAnswer` | `box` (`top`/`bottom`/`left`/`right`), `confidence` (may be nil) | `box.width`, `box.height`, `box.center`, `box.to_pixels(w, h)` |
| `UnknownAnswer` | `raw` | `[]` for answer types added to the API later |

`SystemOneResponse` also has `nouls`, `choices`, `scores`, and `boxes` (hashes filtered by type), plus `each`, `fetch`, `to_h`, and `raw`.

## Images (dreamer-ready)

TypeSafe labels image support "dreamer-ready" (experimental). Place a `TypeSafe::Image` anywhere in the state, instructions, or criteria. The client replaces it with a unique reference, uploads the bytes as multipart, and adds the `TypeSafe-Danger-Zone-Images: true` header.

```ruby
door = TypeSafe::Image.from_path("door.jpg")          # also from_bytes, from_io, from_base64

result = client.system_one(
  state: { camera: door },
  questions: {
    open: TypeSafe.noul("Is the door open?"),
    door: TypeSafe.box("Locate the door.")
  }
)
result[:door].box.to_pixels(1920, 1080)  # => {x:, y:, width:, height:}
```

If you interpolate an image into a string, the client can't see it, so tell it which images to send:

```ruby
client.system_one(state: "Product photo: #{photo}", questions: {...}, assets: [photo])

# or attach for a block; only images whose reference appears in the request are sent
client.with_assets(photo, reference_photo) do
  client.system_one(state: "Is #{photo} the same item as #{reference_photo}?", questions: {...})
end
```

Images also work as examples in criteria:

```ruby
TypeSafe.noul("Is it assembled correctly?",
              criteria: { yes: { description: "Correctly assembled", examples: [good_example] }, no: "Parts missing" })
```

## Long context

```ruby
client.system_one(state: long_contract, questions: {...}, long_context: true)
```

This sends `TypeSafe-Danger-Zone-Long-Context: true`, which raises both context limits to 262k tokens.

## Models

```ruby
models = client.models.list
models.names                       # => ["jev-latest", "jev-1.14", ...]
models["jev-latest"].description
models["jev-latest"].released_on   # => #<Date ...>
```

## Errors

All errors inherit from `TypeSafe::Error`.

```
TypeSafe::Error
├── ConfigurationError
├── APIError                     (#status, #body, #detail, #headers, #request_id, #endpoint)
│   ├── BadRequestError              400
│   │   └── ContextLengthExceededError   400 max_tokens_exceeded
│   ├── AuthenticationError          401
│   ├── PermissionDeniedError        403
│   ├── NotFoundError                404
│   ├── PayloadTooLargeError         413
│   ├── UnsupportedMediaTypeError    415
│   ├── UnprocessableEntityError     422 (#validation_errors)
│   ├── RateLimitError               429 (#retry_after_ms)
│   ├── InternalServerError          5xx
│   │   └── OverloadedError          529
│   └── ResponseValidationError      2xx with a malformed body (#field_path)
└── APIConnectionError           no response
    └── APITimeoutError          (#timeout)
```

The client raises `ArgumentError` before sending when a request is clearly invalid: no questions, too many choices, `NaN` or infinite numbers, or a bad image format.

## Retries

The defaults match TypeSafe's official SDKs: 2 retries, exponential backoff from 0.5 s up to 5 s with 25% jitter, retrying 408, 429, and 5xx responses plus connection errors and timeouts, honoring `Retry-After` and `retry-after-ms`, within a 30 s total budget.

```ruby
TypeSafe::RetryPolicy.new(max_retries: 5, backoff_max: 10, timeout: 60)
TypeSafe::RetryPolicy.none
client.system_one(..., retry_policy: TypeSafe::RetryPolicy.none)  # per call
```

## Per-call options

`system_one` takes `model:`, `assets:`, `images:`, `long_context:`, `timeout:`, `retry_policy:`, and `extra_headers:`. The `Authorization`, `User-Agent`, `Accept`, and `Content-*` headers are protected and can't be overridden.

For anything not wrapped yet, use `client.request(:get, "/v1/whatever")`, which returns `[parsed_json, headers]` and uses the same auth, retries, and errors.

## Development

```sh
bundle install
bundle exec rake test
```
