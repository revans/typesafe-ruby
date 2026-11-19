# frozen_string_literal: true

require "test_helper"

class ImagesTest < Minitest::Test
  include TestHelpers

  def box_body
    system_one_body("door" => { "type" => "box", "confidence" => nil,
                                "box" => { "top" => 0.2, "bottom" => 0.6, "left" => 0.1, "right" => 0.5 } })
  end

  def test_format_detection
    assert_equal "png", TypeSafe::Image.from_bytes(PNG).format
    assert_equal "jpg", TypeSafe::Image.from_bytes(JPEG).format
    assert_equal "jpg", TypeSafe::Image.from_bytes("abc", format: :jpeg).format
    assert_raises(ArgumentError) { TypeSafe::Image.from_bytes("GIF89a") }
  end

  def test_embedded_image_sent_as_multipart_with_header
    image = TypeSafe::Image.from_bytes(PNG, ref: "photo-1")
    stub_request(:post, "#{BASE}/v1/systemone")
      .with(headers: { "TypeSafe-Danger-Zone-Images" => "true" })
      .to_return(json(box_body))

    result = client.system_one(state: { camera: image }, questions: { door: TypeSafe.box("Locate the door") })

    assert_requested(:post, "#{BASE}/v1/systemone") do |req|
      assert_match %r{\Amultipart/form-data; boundary=}, req.headers["Content-Type"]
      body = req.body.b
      assert_includes body, %(name="request")
      assert_includes body, %(name="image-1"; filename="image-1.png")
      assert_includes body, PNG
      json_part = body[%r{Content-Type: application/json\r\n\r\n(.*?)\r\n--}m, 1]
      payload = JSON.parse(json_part)
      assert_equal({ "camera" => "photo-1" }, payload["state"])
      assert_equal({ "type" => "image", "format" => "png", "part" => "image-1" }, payload["assets"]["photo-1"])
      true
    end

    box = result[:door].box
    assert_in_delta 0.4, box.width
    assert_nil result[:door].confidence
    assert_equal({ x: 10, y: 40, width: 40, height: 80 }, box.to_pixels(100, 200))
  end

  def test_base64_upload_mode
    image = TypeSafe::Image.from_bytes(JPEG, ref: "ref-a")
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    client(image_upload: :base64).system_one(
      state: "Product photo: #{image}", questions: { billing: TypeSafe.noul("Damaged?") }, assets: [image]
    )
    assert_requested(:post, "#{BASE}/v1/systemone") do |req|
      asset = captured_json(req)["assets"]["ref-a"]
      asset == { "type" => "image", "format" => "jpg", "data_base64" => Base64.strict_encode64(JPEG) } &&
        req.headers["Typesafe-Danger-Zone-Images"] == "true"
    end
  end

  def test_images_in_criteria_and_instructions
    good = TypeSafe::Image.from_bytes(PNG, ref: "good")
    q = TypeSafe.choice("Which matches? Example:",
                        criteria: { ok: { description: "fine", examples: [good] }, bad: nil })
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    client(image_upload: :base64).system_one(state: "s", questions: { billing: q })
    assert_requested(:post, "#{BASE}/v1/systemone") do |req|
      body = captured_json(req)
      body["questions"]["billing"]["criteria"]["ok"]["examples"] == ["good"] && body["assets"].key?("good")
    end
  end

  def test_with_assets_only_sends_referenced_images
    used = TypeSafe::Image.from_bytes(PNG, ref: "used-ref")
    unused = TypeSafe::Image.from_bytes(PNG, ref: "unused-ref")
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(system_one_body))
    c = client(image_upload: :base64)
    c.with_assets(used, unused) do
      c.system_one(state: "Look at #{used}", questions: { billing: TypeSafe.noul("?") })
    end
    assert_requested(:post, "#{BASE}/v1/systemone") { |req| captured_json(req)["assets"].keys == ["used-ref"] }
  end

  def test_images_header_can_be_forced_off
    stub_request(:post, "#{BASE}/v1/systemone").to_return(json(box_body))
    client(images: false).system_one(state: "s", questions: { door: TypeSafe.box("x") })
    assert_requested(:post, "#{BASE}/v1/systemone") { |req| !req.headers.key?("Typesafe-Danger-Zone-Images") }
  end
end
