module GitProviders
  class Adapter
    def installation_setup(state:, redirect_uri:)
      raise NotImplementedError
    end

    def installation(id:)
      raise NotImplementedError
    end

    def open_session(installation_id:)
      raise NotImplementedError
    end

    def disconnect(installation_id:)
      raise NotImplementedError
    end

    def map_user(access_token:)
      raise NotImplementedError
    end

    def verify_webhook(delivery_id:, event_type:, signature:, body:)
      raise NotImplementedError
    end
  end
end
