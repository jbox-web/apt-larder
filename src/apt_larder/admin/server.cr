require "base64"
require "crypto/subtle"

module AptLarder
  module Admin
    # Routes requests between Api and Handler and authenticates them: /api/*
    # accepts the Bearer token or the UI's Basic credentials, everything else
    # takes the Basic credentials only.
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

      # Returns `true` when the request may use the API: nothing is configured,
      # or it carries the API token, or it carries the UI credentials (the web
      # UI calls the API with the Basic credentials the browser already holds).
      private def api_authorized?(req : HTTP::Request) : Bool
        return true unless @config.auth_configured?
        bearer_ok?(req) || basic_ok?(req)
      end

      # Returns `true` when Basic Auth credentials match, or when no credentials
      # are configured.
      private def ui_authorized?(req : HTTP::Request) : Bool
        return true unless @config.ui_auth?
        basic_ok?(req)
      end

      # Constant-time comparison of the Bearer token; `false` when no token is
      # configured, so an empty token never matches an empty header.
      private def bearer_ok?(req : HTTP::Request) : Bool
        return false if @config.api_token.empty?
        provided = req.headers["Authorization"]? || ""
        Crypto::Subtle.constant_time_compare(provided, "Bearer #{@config.api_token}")
      end

      # Checks HTTP Basic credentials against `ui_user` / `ui_password`;
      # `false` when they are not configured. Decoding failures (malformed
      # Base64) return `false`.
      private def basic_ok?(req : HTTP::Request) : Bool
        return false unless @config.ui_auth?
        auth = req.headers["Authorization"]?
        return false unless auth && auth.starts_with?("Basic ")
        decoded = Base64.decode_string(auth[6..]) rescue return false
        user, _, pass = decoded.partition(":")
        # Compare both fields unconditionally (no && short-circuit) so the
        # response time does not reveal which of the two was wrong.
        user_ok = Crypto::Subtle.constant_time_compare(user, @config.ui_user)
        pass_ok = Crypto::Subtle.constant_time_compare(pass, @config.ui_password)
        user_ok && pass_ok
      end
    end
  end
end
