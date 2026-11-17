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
    # | GET | `/api/cache` | Paginated cache entry list (`prefix`, `search`, `sort`, `order`, `page`, `per_page`) |
    # | DELETE | `/api/cache` | Flush the entire cache |
    # | DELETE | `/api/cache/:key` | Invalidate one entry (URL-encoded key) |
    # | POST | `/api/evict` | Run eviction with optional `max_age_days` |
    #
    # State-changing requests (anything but GET/HEAD) carrying an `Origin`
    # header that is not the admin server itself are refused with 403, and
    # request bodies must be declared as JSON: together they keep a web page
    # open in the operator's browser from driving the API cross-site.
    class Api
      Log = ::Log.for("apt-larder.admin")

      # Upper bound of `per_page` on `GET /api/cache`.
      MAX_PER_PAGE = 200

      # Upper bound of `max_age_days` on `POST /api/evict` (a century). Keeps
      # the cutoff computation far away from the limits of `Time`.
      MAX_EVICT_DAYS = 36_500

      def initialize(@cache : Cache, @proxy : Proxy, @default_evict_days : Int32 = 30)
      end

      # Routes the request to the appropriate handler.
      def handle(ctx : HTTP::Server::Context) : Nil
        req = ctx.request
        res = ctx.response
        res.content_type = "application/json"

        path = req.path

        unless same_origin?(req)
          error(res, HTTP::Status::FORBIDDEN, "cross-origin request refused")
          res.flush
          return
        end

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
            error(res, HTTP::Status::NOT_FOUND, "not found")
          end
        end
        res.flush
      end

      # Returns `false` for a state-changing request sent by a page of another
      # origin. Browsers attach `Origin` to every cross-origin POST/DELETE, and
      # to same-origin ones too: it must then name the very host the request
      # was addressed to. Requests without `Origin` (curl, the CLI, Prometheus)
      # are not browser-driven and pass.
      private def same_origin?(req : HTTP::Request) : Bool
        return true if req.method.in?("GET", "HEAD")
        origin = req.headers["Origin"]?
        return true unless origin
        host = req.headers["Host"]?
        return false unless host
        uri = URI.parse(origin) rescue return false
        origin_host = uri.host
        return false unless origin_host
        authority = uri.port ? "#{origin_host}:#{uri.port}" : origin_host
        authority.compare(host, case_insensitive: true) == 0
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
            j.field "cache_bytes", @cache.total_bytes
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
          {"cache_bytes", "gauge", "Current disk space used by the cached files, in bytes.", @cache.total_bytes},
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
        per_page = (params["per_page"]?.try(&.to_i?) || 50).clamp(1, MAX_PER_PAGE)
        search = params["search"]? || ""
        sort = Cache::EntrySort.parse?(params["sort"]? || "") || Cache::EntrySort::Key
        descending = params["order"]? == "desc"
        result = @cache.entries(prefix: prefix, page: page, per_page: per_page,
          search: search, sort: sort, descending: descending)
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
        # Cache#clear deletes in a single scan without materializing per-entry
        # structs, so it stays cheap even on a very large cache.
        deleted = @cache.clear
        json(res) { |j| j.object { j.field "deleted", deleted } }
      end

      private def handle_invalidate(encoded_key : String, res : HTTP::Server::Response) : Nil
        key = URI.decode(encoded_key)
        # Reject path traversal before touching the filesystem — a decoded key
        # like "../../etc/passwd" must never reach exists?/invalidate. Reject
        # sidecar keys too: a sidecar is not an entry, and deleting a .sha256
        # alone would leave its data file unverified (valid? trusts it). Same
        # for a temporary download file: it belongs to a download in flight.
        if key.includes?("..") || Cache.sidecar?(key) || Cache.temp?(key)
          error(res, HTTP::Status::BAD_REQUEST, "invalid key")
          return
        end
        unless @cache.exists?(key)
          error(res, HTTP::Status::NOT_FOUND, "not found")
          return
        end
        @cache.invalidate(key)
        res.status = HTTP::Status::NO_CONTENT
      end

      private def handle_evict(req : HTTP::Request, res : HTTP::Server::Response) : Nil
        max_age_days = @default_evict_days
        body = req.body.try(&.gets_to_end) || ""
        unless body.empty?
          unless json_body?(req)
            error(res, HTTP::Status::UNSUPPORTED_MEDIA_TYPE, "body must be application/json")
            return
          end
          fields = (JSON.parse(body) rescue nil).try(&.as_h?)
          unless fields
            error(res, HTTP::Status::BAD_REQUEST, "body must be a JSON object")
            return
          end
          if value = fields["max_age_days"]?
            days = value.as_i?
            unless days && days.in?(1..MAX_EVICT_DAYS)
              error(res, HTTP::Status::BAD_REQUEST, "max_age_days must be an integer between 1 and #{MAX_EVICT_DAYS}")
              return
            end
            max_age_days = days
          end
        end
        # No explicit age and `evict_after_days: 0`: time-based eviction is
        # disabled, which must never read as "everything is older than 0 days".
        deleted, freed = max_age_days > 0 ? @cache.evict_stale(max_age_days.days) : {0, 0_i64}
        json(res) do |j|
          j.object do
            j.field "deleted", deleted
            j.field "freed_bytes", freed
          end
        end
      end

      # `true` when the request declares a JSON body (parameters such as
      # `; charset=utf-8` are ignored).
      private def json_body?(req : HTTP::Request) : Bool
        media_type = req.headers["Content-Type"]?.try(&.partition(';')[0].strip.downcase)
        media_type == "application/json"
      end

      private def error(res : HTTP::Server::Response, status : HTTP::Status, message : String) : Nil
        res.status = status
        json(res) { |j| j.object { j.field "error", message } }
      end

      private def json(res : HTTP::Server::Response, &) : Nil
        body = JSON.build { |j| yield j }
        res.content_length = body.bytesize
        res.print(body)
      end
    end
  end
end
