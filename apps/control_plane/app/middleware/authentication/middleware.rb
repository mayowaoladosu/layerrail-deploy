module Authentication
  class Middleware
    COOKIE_NAME = "lrail_auth".freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if env["lrail.authenticated_principal"]

      request = Rack::Request.new(env)
      method, token = credentials(request)
      if token
        authenticated = Sessions.authenticate(token:, kind: method == "bearer" ? :api : :web)
        if authenticated
          env["lrail.authenticated_principal"] = authenticated.user
          env["lrail.authentication_session"] = authenticated.session
          env["lrail.authentication_method"] = method
        end
      end

      @app.call(env)
    end

    private

    def credentials(request)
      authorization = request.get_header("HTTP_AUTHORIZATION").to_s
      if authorization.present?
        match = authorization.match(/\ABearer ([^\s]+)\z/i)
        return [ "bearer", match&.captures&.first ]
      end

      [ "cookie", request.cookies[COOKIE_NAME] ]
    end
  end
end
