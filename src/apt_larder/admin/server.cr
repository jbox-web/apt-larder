require "base64"

module AptLarder
  module Admin
    # Routes requests between Api and Handler, enforcing independent auth
    # policies: Bearer token for /api/*, HTTP Basic for everything else.
    #
    # The two handlers are completely independent — Api has no knowledge of
    # the UI, and Handler has no knowledge of the API.
    class Server
      # *evict_after_days* is forwarded to `Api` as the default for
      # `POST /api/evict` when no body is provided.
      def initialize(@config : AdminConfig, cache : Cache, proxy : Proxy, evict_after_days : Int32 = 30)
        @api = Api.new(cache, proxy, evict_after_days)
        @handler = Handler.new
      end

      # Handles a single request: authenticates then dispatches.
      def handle(ctx : HTTP::Server::Context) : Nil
        req = ctx.request
        res = ctx.response

        if req.path.starts_with?("/api/")
          unless api_authorized?(req)
            res.status = HTTP::Status::UNAUTHORIZED
            res.headers["WWW-Authenticate"] = %(Bearer realm="apt-larder api")
            res.content_type = "application/json"
            res.print %({"error":"unauthorized"})
            return
          end
          @api.handle(ctx)
        else
          unless ui_authorized?(req)
            res.status = HTTP::Status::UNAUTHORIZED
            res.headers["WWW-Authenticate"] = %(Basic realm="apt-larder admin")
            return
          end
          @handler.handle(ctx)
        end
      end

      # Starts the admin HTTP server. Blocks until the server is closed.
      def start : Nil
        server = HTTP::Server.new { |ctx| handle(ctx) }
        addr = server.bind_tcp(@config.host, @config.port)
        Log.info { "admin server listening on http://#{addr}" }
        server.listen
      end

      # Returns `true` when the API token matches, or when no token is configured.
      private def api_authorized?(req : HTTP::Request) : Bool
        return true if @config.api_token.empty?
        req.headers["Authorization"]? == "Bearer #{@config.api_token}"
      end

      # Returns `true` when Basic Auth credentials match, or when no credentials
      # are configured. Decoding failures (malformed Base64) return `false`.
      private def ui_authorized?(req : HTTP::Request) : Bool
        return true if @config.ui_user.empty?
        auth = req.headers["Authorization"]?
        return false unless auth && auth.starts_with?("Basic ")
        decoded = Base64.decode_string(auth[6..]) rescue return false
        user, _, pass = decoded.partition(":")
        user == @config.ui_user && pass == @config.ui_password
      end
    end
  end
end
