module AptLarder
  module Admin
    # Handles all /api/* requests, returning JSON responses.
    #
    # Each endpoint operates directly on the shared `Cache` and `Proxy`
    # instances — no locking beyond what those classes already provide.
    #
    # ## Endpoints
    #
    # | Method | Path | Description |
    # |--------|------|-------------|
    # | GET | `/api/health` | Server status and version |
    # | GET | `/api/stats` | Cumulative proxy counters |
    # | GET | `/api/cache` | Paginated cache entry list |
    # | DELETE | `/api/cache` | Flush the entire cache |
    # | DELETE | `/api/cache/:key` | Invalidate one entry (URL-encoded key) |
    # | POST | `/api/evict` | Run eviction with optional `max_age_days` |
    class Api
      Log = ::Log.for("apt-larder.admin")

      def initialize(@cache : Cache, @proxy : Proxy, @default_evict_days : Int32 = 30)
      end

      # Routes the request to the appropriate handler.
      def handle(ctx : HTTP::Server::Context) : Nil
        req = ctx.request
        res = ctx.response
        res.content_type = "application/json"

        path = req.path

        case {req.method, path}
        when {"GET", "/api/health"}
          handle_health(res)
        when {"GET", "/api/stats"}
          handle_stats(res)
        when {"GET", "/api/metrics"}
          handle_metrics(res)
        when {"GET", "/api/cache"}
          handle_list(req, res)
        when {"DELETE", "/api/cache"}
          handle_flush(res)
        when {"POST", "/api/evict"}
          handle_evict(req, res)
        else
          if req.method == "DELETE" && path.starts_with?("/api/cache/")
            handle_invalidate(path["/api/cache/".size..], res)
          else
            res.status = HTTP::Status::NOT_FOUND
            json(res) { |j| j.object { j.field "error", "not found" } }
          end
        end
        res.flush
      end

      private def handle_health(res : HTTP::Server::Response) : Nil
        json(res) do |j|
          j.object do
            j.field "status", "ok"
            j.field "version", AptLarder.version
          end
        end
      end

      private def handle_stats(res : HTTP::Server::Response) : Nil
        s = @proxy.stats
        json(res) do |j|
          j.object do
            j.field "hits", s[:hits]
            j.field "misses", s[:misses]
            j.field "revalidations", s[:revalidations]
            j.field "errors", s[:errors]
            j.field "bytes", s[:bytes]
            j.field "tunnels", s[:tunnels]
          end
        end
      end

      private def handle_metrics(res : HTTP::Server::Response) : Nil
        s = @proxy.stats
        entries = @cache.entry_count
        res.content_type = "text/plain; version=0.0.4"
        io = IO::Memory.new
        {
          {"hits_total", "counter", "Total cache hits served to clients.", s[:hits]},
          {"misses_total", "counter", "Total upstream fetches triggered.", s[:misses]},
          {"revalidations_total", "counter", "Total 304 Not Modified revalidations.", s[:revalidations]},
          {"errors_total", "counter", "Total requests that resulted in an error.", s[:errors]},
          {"bytes_served_total", "counter", "Total bytes written to clients from cache.", s[:bytes]},
          {"tunnels_total", "counter", "Total CONNECT tunnels successfully established.", s[:tunnels]},
          {"cache_entries", "gauge", "Current number of files tracked in the cache.", entries.to_i64},
        }.each do |name, type, help, value|
          io << "# HELP apt_larder_#{name} #{help}\n"
          io << "# TYPE apt_larder_#{name} #{type}\n"
          io << "apt_larder_#{name} #{value}\n"
        end
        res.print io.to_s
      end

      private def handle_list(req : HTTP::Request, res : HTTP::Server::Response) : Nil
        params = URI::Params.parse(req.query || "")
        prefix = params["prefix"]? || ""
        page = (params["page"]?.try(&.to_i?) || 1).clamp(1, Int32::MAX)
        per_page = (params["per_page"]?.try(&.to_i?) || 50).clamp(1, 200)
        result = @cache.entries(prefix, page, per_page)
        json(res) do |j|
          j.object do
            j.field "total", result[:total]
            j.field "page", page
            j.field "per_page", per_page
            j.field "entries" do
              j.array do
                result[:entries].each do |entry|
                  j.object do
                    j.field "key", entry.key
                    j.field "size", entry.size
                    j.field "mtime", entry.mtime.to_rfc3339
                    j.field "immutable", entry.immutable?
                  end
                end
              end
            end
          end
        end
      end

      private def handle_flush(res : HTTP::Server::Response) : Nil
        # Single scan: collect all keys then invalidate in one pass.
        # Count invalidations actually performed rather than trusting :total,
        # which could differ if entries disappear between scan and invalidation.
        result = @cache.entries(per_page: Int32::MAX)
        deleted = 0
        result[:entries].each do |entry|
          @cache.invalidate(entry.key)
          deleted += 1
        end
        json(res) { |j| j.object { j.field "deleted", deleted } }
      end

      private def handle_invalidate(encoded_key : String, res : HTTP::Server::Response) : Nil
        key = URI.decode(encoded_key)
        # Reject path traversal before touching the filesystem — a decoded key
        # like "../../etc/passwd" must never reach exists?/invalidate.
        if key.includes?("..")
          res.status = HTTP::Status::BAD_REQUEST
          json(res) { |j| j.object { j.field "error", "invalid key" } }
          return
        end
        unless @cache.exists?(key)
          res.status = HTTP::Status::NOT_FOUND
          json(res) { |j| j.object { j.field "error", "not found" } }
          return
        end
        @cache.invalidate(key)
        res.status = HTTP::Status::NO_CONTENT
      end

      private def handle_evict(req : HTTP::Request, res : HTTP::Server::Response) : Nil
        max_age_days = @default_evict_days
        if body = req.body.try(&.gets_to_end)
          unless body.empty?
            if (parsed = JSON.parse(body) rescue nil) && (days = parsed["max_age_days"]?.try(&.as_i?))
              max_age_days = days
            end
          end
        end
        deleted, freed = @cache.evict_stale(max_age_days.days)
        json(res) do |j|
          j.object do
            j.field "deleted", deleted
            j.field "freed_bytes", freed
          end
        end
      end

      private def json(res : HTTP::Server::Response, &) : Nil
        body = JSON.build { |j| yield j }
        res.content_length = body.bytesize
        res.print(body)
      end
    end
  end
end
