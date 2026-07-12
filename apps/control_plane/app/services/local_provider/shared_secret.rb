module LocalProvider
  class SharedSecret
    def self.read
      path = Pathname(ENV.fetch("LOCAL_PROVIDER_SHARED_SECRET_FILE", "/run/lrail-provider-auth/secret"))
      secret = path.binread.strip
      raise ArgumentError unless secret.bytesize.between?(32, 4096)

      secret
    end
  end
end
