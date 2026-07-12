module LocalProvider
  class RequestAuthentication
    MAX_CLOCK_SKEW = 60.seconds

    def self.valid?(request:, now: Time.current)
      timestamp = Integer(request.headers["X-Lrail-Timestamp"], 10)
      request_id = request.headers["X-Lrail-Request-Id"].to_s
      signature = request.headers["X-Lrail-Signature"].to_s
      return false unless (now.to_i - timestamp).abs <= MAX_CLOCK_SKEW
      return false unless Events::Envelope::UUID_PATTERN.match?(request_id)
      return false unless signature.match?(/\Asha256=[0-9a-f]{64}\z/)

      input = [ timestamp, request_id, request.request_method, request.path, request.raw_post ].join("\n")
      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", shared_secret, input)}"
      ActiveSupport::SecurityUtils.secure_compare(signature, expected)
    rescue ArgumentError, Errno::ENOENT
      false
    end

    def self.shared_secret
      path = Pathname(ENV.fetch("LOCAL_PROVIDER_SHARED_SECRET_FILE", "/run/lrail-provider-auth/secret"))
      secret = path.binread.strip
      raise ArgumentError if secret.bytesize < 32 || secret.bytesize > 4096

      secret
    end
    private_class_method :shared_secret
  end
end
