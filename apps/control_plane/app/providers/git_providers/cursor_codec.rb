require "base64"
require "openssl"

module GitProviders
  class CursorCodec
    def initialize(secret:)
      @secret = secret
    end

    def encode(scope:, offset:)
      payload = Base64.urlsafe_encode64(
        JSON.generate("version" => 1, "scope" => scope, "offset" => offset),
        padding: false
      )
      signature = OpenSSL::HMAC.hexdigest("SHA256", @secret, payload)

      "#{payload}.#{signature}"
    end

    def decode(cursor, scope:)
      payload, signature = cursor.to_s.split(".", 2)
      return unless payload.present? && signature.present?

      expected = OpenSSL::HMAC.hexdigest("SHA256", @secret, payload)
      return unless secure_compare(signature, expected)

      data = JSON.parse(Base64.urlsafe_decode64(payload))
      offset = data["offset"]
      return unless data == { "version" => 1, "scope" => scope, "offset" => offset }
      return unless offset.is_a?(Integer) && offset >= 0

      offset
    rescue ArgumentError, JSON::ParserError
      nil
    end

    private

    def secure_compare(value, expected)
      value.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(value, expected)
    end
  end
end
