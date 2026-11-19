# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "stringio"
require "uri"
require "zlib"

module TypeSafe
  # Low-level HTTP plumbing: body encoding, compression, multipart framing,
  # and the Net::HTTP call itself. Retries live in Client.
  module HTTP
    COMPRESSION_THRESHOLD = 1024
    SECRET_HEADER = /authorization|api[-_]?key|cookie|token|secret/i

    Response = Struct.new(:status, :headers, :body, keyword_init: true)

    # A fully encoded request body.
    EncodedBody = Struct.new(:bytes, :content_type, :content_encoding, :description, keyword_init: true)

    module_function

    def encode_json(payload, compression:)
      json = generate_json(payload)
      bytes, encoding = compress(json, compression)
      EncodedBody.new(bytes: bytes, content_type: "application/json", content_encoding: encoding, description: json)
    end

    def encode_multipart(payload, parts)
      json = generate_json(payload)
      boundary = "typesafe-#{SecureRandom.hex(16)}"
      io = StringIO.new(+"".b)
      io << "--#{boundary}\r\n"
      io << "Content-Disposition: form-data; name=\"request\"\r\n"
      io << "Content-Type: application/json\r\n\r\n"
      io << json.b << "\r\n"
      parts.each do |name, image|
        io << "--#{boundary}\r\n"
        io << "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{name}.#{image.format}\"\r\n"
        io << "Content-Type: #{image.content_type}\r\n\r\n"
        io << image.data << "\r\n"
      end
      io << "--#{boundary}--\r\n"
      description = "#{json} [+#{parts.size} image part(s), #{parts.sum { |_, i| i.bytesize }} bytes]"
      EncodedBody.new(bytes: io.string, content_type: "multipart/form-data; boundary=#{boundary}",
                      content_encoding: nil, description: description)
    end

    def generate_json(payload)
      JSON.generate(payload)
    rescue JSON::GeneratorError => e
      raise ArgumentError, "request is not valid JSON: #{e.message}"
    end

    def compress(bytes, compression)
      return [bytes, nil] if !compression || bytes.bytesize < COMPRESSION_THRESHOLD

      case compression
      when :gzip then [Zlib.gzip(bytes), "gzip"]
      when :zstd then [zstd_compress(bytes), "zstd"]
      else raise ConfigurationError, "unknown compression #{compression.inspect}; use :gzip, :zstd, or false"
      end
    end

    def zstd_compress(bytes)
      require "zstd-ruby"
      Zstd.compress(bytes)
    rescue LoadError
      raise ConfigurationError, "compression: :zstd requires the zstd-ruby gem"
    end

    # Performs one HTTP request. Returns a Response or raises
    # APIConnectionError / APITimeoutError.
    def perform(method:, url:, headers:, timeout:, body: nil)
      uri = URI(url)
      request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      headers.each { |k, v| request[k] = v }
      request.body = body if body

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout

      response = http.start { |conn| conn.request(request) }
      Response.new(
        status: response.code.to_i,
        headers: response.each_header.to_h { |k, v| [k.downcase, v] },
        body: response.body.to_s
      )
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error => e
      raise APITimeoutError.new("Request timed out (#{e.class.name.split("::").last})",
                                timeout: timeout, endpoint: endpoint(method, uri))
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse => e
      raise APIConnectionError.new("Connection error: #{e.class}: #{e.message}", endpoint: endpoint(method, uri))
    end

    def endpoint(method, uri)
      return nil unless uri

      port = uri.port == uri.default_port ? "" : ":#{uri.port}"
      "#{method.to_s.upcase} #{uri.scheme}://#{uri.host}#{port}#{uri.path}"
    end

    def parse_body(response)
      return nil if response.body.empty?

      JSON.parse(response.body)
    rescue JSON::ParserError
      response.body
    end

    def redact(headers)
      headers.to_h { |k, v| [k, SECRET_HEADER.match?(k) ? "[REDACTED]" : v] }
    end
  end
end
