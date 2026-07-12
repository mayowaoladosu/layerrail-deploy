module Authentication
  module TokenDigests
    module_function

    def token(value)
      Digest::SHA256.hexdigest(value.to_s)
    end

    def context(value)
      return if value.blank?

      OpenSSL::HMAC.hexdigest("SHA256", context_key, value.to_s)
    end

    def context_key
      ENV["RAILS_ENCRYPTION_KEY"].presence || ENV.fetch("ENCRYPTION_KEY")
    end
  end
end
