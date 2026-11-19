# frozen_string_literal: true

require "base64"
require "securerandom"
require "pathname"

module TypeSafe
  # An image asset for a System One request (PNG or JPEG stills only).
  #
  # Put an Image anywhere in +state+, a question's +instructions+, or its
  # +criteria+ and the client replaces it with a unique reference and uploads
  # the bytes. You can also interpolate it into a string (+"Photo: #{image}"+),
  # in which case pass it in +assets:+ (or use Client#with_assets) so the
  # client knows to send it.
  #
  #   photo = TypeSafe::Image.from_path("door.jpg")
  #   client.system_one(state: { camera: photo }, questions: { open: TypeSafe::Noul.new("Is the door open?") })
  class Image
    FORMATS = %w[png jpg jpeg].freeze
    PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze
    JPEG_MAGIC = "\xFF\xD8\xFF".b.freeze

    attr_reader :data, :format, :ref, :filename

    # @param path [String, Pathname]
    def self.from_path(path, format: nil, ref: nil)
      path = Pathname(path)
      new(path.binread, format: format, ref: ref, filename: path.basename.to_s)
    end

    # @param io [#read]
    def self.from_io(io, format: nil, ref: nil, filename: nil)
      new(io.read, format: format, ref: ref, filename: filename)
    end

    # @param bytes [String] raw image bytes
    def self.from_bytes(bytes, format: nil, ref: nil, filename: nil)
      new(bytes, format: format, ref: ref, filename: filename)
    end

    # @param encoded [String] standard base64 (a +data:+ URI prefix is stripped)
    def self.from_base64(encoded, format: nil, ref: nil, filename: nil)
      encoded = encoded.sub(/\Adata:[^,]*,/, "")
      new(Base64.decode64(encoded), format: format, ref: ref, filename: filename)
    end

    # @param data [String] raw bytes
    # @param format [String, Symbol, nil] "png", "jpg" or "jpeg"; detected from bytes when nil
    # @param ref [String, nil] the placeholder text; defaults to a fresh UUID-based reference
    def initialize(data, format: nil, ref: nil, filename: nil)
      raise ArgumentError, "image data must be a String of bytes" unless data.is_a?(String)
      raise ArgumentError, "image data is empty" if data.empty?

      @data = data.b.freeze
      @format = normalize_format(format || self.class.detect_format(@data))
      @ref = (ref || "typesafe-image-#{SecureRandom.uuid}").to_s.freeze
      raise ArgumentError, "image ref must not be empty" if @ref.empty?

      @filename = filename || "#{@ref}.#{@format}"
      freeze
    end

    # The placeholder that stands for this image inside request strings.
    def to_s
      ref
    end

    def inspect
      "#<#{self.class.name} ref=#{ref.inspect} format=#{format} bytes=#{data.bytesize}>"
    end

    def bytesize
      data.bytesize
    end

    def content_type
      format == "png" ? "image/png" : "image/jpeg"
    end

    def base64
      Base64.strict_encode64(data)
    end

    # Wire-format asset hash for a JSON (base64) request.
    def to_base64_asset
      { "type" => "image", "format" => format, "data_base64" => base64 }
    end

    # Wire-format asset hash for a multipart request.
    def to_part_asset(part_name)
      { "type" => "image", "format" => format, "part" => part_name }
    end

    def self.detect_format(bytes)
      return "png" if bytes.start_with?(PNG_MAGIC)
      return "jpg" if bytes.start_with?(JPEG_MAGIC)

      raise ArgumentError, "could not detect image format (only PNG and JPEG are supported); pass format:"
    end

    private

    def normalize_format(value)
      fmt = value.to_s.downcase
      fmt = "jpg" if fmt == "jpeg"
      raise ArgumentError, "unsupported image format #{value.inspect}; use png or jpg" unless FORMATS.include?(fmt)

      fmt
    end
  end
end
