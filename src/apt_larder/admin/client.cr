module AptLarder
  module Admin
    # Raised by `Client` on non-2xx responses or network failures.
    class Error < Exception; end

    # HTTP client for the apt-larder admin REST API.
    #
    # Reads the admin host, port, and Bearer token from `AdminConfig`.
    # All methods raise `Admin::Error` on non-2xx responses or network failures.
    class Client
      def initialize(@config : AdminConfig)
      end

      # Returns `{"status" => "ok", "version" => "..."}`.
      def health : JSON::Any
        get("/api/health")
      end

      # Returns cumulative counters: hits, misses, revalidations, errors, bytes.
      def stats : JSON::Any
        get("/api/stats")
      end

      # Returns a paginated list of cache entries.
      def cache_list(prefix : String = "", page : Int32 = 1, per_page : Int32 = 50) : JSON::Any
        params = URI::Params.build do |params_builder|
          params_builder.add("prefix", prefix) unless prefix.empty?
          params_builder.add("page", page.to_s)
          params_builder.add("per_page", per_page.to_s)
        end
        get("/api/cache?#{params}")
      end

      # Flushes the entire cache and returns `{"deleted" => N}`.
      def cache_flush : JSON::Any
        delete("/api/cache")
      end

      # Invalidates a single entry identified by *key* (plain, not URL-encoded).
      # Returns nil on 204, raises on 404 or other errors.
      def cache_invalidate(key : String) : Nil
        encoded = URI.encode_path_segment(key)
        response = http_request("DELETE", "/api/cache/#{encoded}")
        return if response.status_code == 204
        raise Admin::Error.new("#{response.status_code} #{response.body.strip}")
      end

      # Runs eviction with an optional *max_age_days* override.
      # Returns `{"deleted" => N, "freed_bytes" => N}`.
      def evict(max_age_days : Int32? = nil) : JSON::Any
        body = max_age_days ? %({"max_age_days":#{max_age_days}}) : ""
        post("/api/evict", body)
      end

      private def get(path : String) : JSON::Any
        parse(http_request("GET", path))
      end

      private def delete(path : String) : JSON::Any
        parse(http_request("DELETE", path))
      end

      private def post(path : String, body : String) : JSON::Any
        parse(http_request("POST", path, body))
      end

      private def http_request(method : String, path : String, body : String = "") : HTTP::Client::Response
        url = "http://#{@config.host}:#{@config.port}#{path}"
        h = HTTP::Headers{"Content-Type" => "application/json"}
        h["Authorization"] = "Bearer #{@config.api_token}" unless @config.api_token.empty?
        response = HTTP::Client.exec(method, url, headers: h, body: body)
        unless response.success?
          raise Admin::Error.new("#{response.status_code} #{response.body.strip}")
        end
        response
      rescue ex : IO::Error
        raise Admin::Error.new("cannot reach admin server at #{@config.host}:#{@config.port} — #{ex.message}")
      end

      private def parse(response : HTTP::Client::Response) : JSON::Any
        JSON.parse(response.body)
      rescue ex : JSON::ParseException
        raise Admin::Error.new("invalid JSON response: #{ex.message}")
      end
    end
  end
end
