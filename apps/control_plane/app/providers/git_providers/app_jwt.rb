require "base64"
require "openssl"

module GitProviders
  class AppJwt
    def initialize(app_id:, private_key:, clock:)
      @app_id = app_id.to_s
      @private_key = OpenSSL::PKey::RSA.new(private_key)
      @clock = clock
    end

    def issue
      issued_at = @clock.call.to_i - 60
      header = encode("alg" => "RS256", "typ" => "JWT")
      payload = encode(
        "iat" => issued_at,
        "exp" => issued_at + 600,
        "iss" => @app_id
      )
      signing_input = "#{header}.#{payload}"
      signature = @private_key.sign(OpenSSL::Digest::SHA256.new, signing_input)

      "#{signing_input}.#{Base64.urlsafe_encode64(signature, padding: false)}"
    end

    def inspect
      "#<#{self.class.name} app_id=#{@app_id.inspect} private_key=[REDACTED]>"
    end

    private

    def encode(value)
      Base64.urlsafe_encode64(JSON.generate(value), padding: false)
    end
  end
end
