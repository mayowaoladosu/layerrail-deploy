require "net/http"

module GitProviders
  module Http
    Response = Data.define(:status, :headers, :body)

    class TransportError < StandardError; end

    class NetTransport
      BASE_URI = URI("https://api.github.com")

      def request(method:, path:, headers:, query: nil, body: nil)
        uri = BASE_URI.dup
        uri.path = path
        uri.query = URI.encode_www_form(query) if query.present?
        request = request_class(method).new(uri)
        default_headers.merge(headers).each { |name, value| request[name] = value }
        request.body = JSON.generate(body) if body

        response = Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: true,
          open_timeout: 5,
          read_timeout: 15
        ) { |http| http.request(request) }

        Response.new(
          status: response.code.to_i,
          headers: response.each_header.to_h.freeze,
          body: parse_body(response.body)
        )
      rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => error
        raise TransportError, error.class.name
      end

      def inspect
        "#<#{self.class.name} base_uri=#{BASE_URI}>"
      end

      private

      def request_class(method)
        {
          get: Net::HTTP::Get,
          post: Net::HTTP::Post,
          delete: Net::HTTP::Delete
        }.fetch(method)
      end

      def default_headers
        {
          "Accept" => "application/vnd.github+json",
          "Content-Type" => "application/json",
          "User-Agent" => "Lrail-Control-Plane",
          "X-GitHub-Api-Version" => "2022-11-28"
        }
      end

      def parse_body(body)
        return {} if body.blank?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
