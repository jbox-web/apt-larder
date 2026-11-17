module AptLarder
  # HTTP handler that resolves incoming APT requests to a cache key and an
  # upstream URL, ensures the file is cached, then streams it to the client.
  #
  # Two URL forms are supported:
  # - **Proxy mode** — the request resource is an absolute URL
  #   (`GET http://deb.debian.org/…`). APT uses this when
  #   `Acquire::http::Proxy` is set.
  # - **Host-in-path mode** — the upstream host is embedded as the first
  #   path segment (`GET /deb.debian.org/debian/…`). Used when sources.list
  #   entries are rewritten to point directly at apt-larder.
  #
  # Immutability heuristic: `.deb`, `.udeb`, `.ddeb` files and paths
  # containing `/pool/` or `/by-hash/` are cached forever and verified with
  # SHA256 on first serve. All other paths are treated as index files and
  # refreshed after `index_ttl` minutes using conditional GET.
  class Proxy
    Log = ::Log.for("apt-larder.proxy")

    # Pre-computed at compile time; avoids string interpolation on every download.
    USER_AGENT = "apt-larder/#{AptLarder::VERSION}"

    # Origin-form path answered by the liveness probe.
    #
    # The leading underscore is what keeps it collision-free: in host-in-path
    # mode the first segment is a mirror hostname, and `_health` is not a legal
    # hostname, so no `sources.list` entry can ever produce this resource.
    HEALTH_PATH = "/_health"

    private enum CacheResult
      Hit
      Miss
      Revalidated
      Error
    end

    # Outcome of parsing a `Range` header against a file.
    private enum RangeKind
      # No usable range: serve the whole file.
      Whole
      # A satisfiable range: serve 206.
      Partial
      # Well-formed but beyond the file: answer 416.
      Unsatisfiable
    end

    # `parse_range` results that carry no bounds.
    private WHOLE_FILE    = {RangeKind::Whole, 0_i64, 0_i64}
    private UNSATISFIABLE = {RangeKind::Unsatisfiable, 0_i64, 0_i64}

    # Carries the leader's result to all concurrent waiters for the same key.
    # Safety comes from the happens-before edge between the leader's
    # `channel.close` and each waiter's `channel.receive?`: the leader writes
    # `value`/`status` before closing, so every woken waiter observes them.
    # *status* is the HTTP status code to return to the client on error
    # (upstream 404 is passed through; gateway errors use 502).
    #
    # One instance per flight: the leader registers it in `@sf_refs` when its
    # block starts and removes it when the block ends, and a request picks up
    # the instance of the flight it is about to join before blocking on it.
    private class ResultRef
      property value : CacheResult?
      property status : Int32 = 502

      def initialize
        @value = nil
      end
    end

    # Creates a new proxy.
    #
    # - *cache* — cache store shared with the eviction loop
    # - *sf* — single-flight coordinator shared across all concurrent requests
    # - *index_ttl* — minutes before index files are revalidated (0 = always stale)
    # - *max_redirects* — maximum number of upstream redirects to follow
    # - *connect_timeout* / *read_timeout* — upstream timeouts in seconds
    # - *quiet* — when `true`, only MISS and ERR are logged
    # - *allow_local_targets* — when `false`, a client cannot make the proxy
    #   reach a loopback, unspecified or link-local address (remap targets are
    #   exempt: they come from the configuration)
    # - *connect_ports* — the only ports a CONNECT tunnel may be opened to
    def initialize(
      @cache : Cache,
      @sf : SingleFlight,
      @max_redirects : Int32,
      index_ttl : Int32,
      connect_timeout : Int32,
      read_timeout : Int32,
      @quiet : Bool = false,
      @remaps : Hash(String, String) = {} of String => String,
      @allow_local_targets : Bool = false,
      connect_ports : Array(Int32) = [443],
    )
      @connect_ports = connect_ports.to_set
      @index_ttl_span = index_ttl.minutes
      @connect_timeout = connect_timeout.seconds
      @read_timeout = read_timeout.seconds
      @pool = ConnectionPool.new
      @sf_refs = {} of String => ResultRef
      @sf_refs_mutex = Mutex.new
      @stat_hits = Atomic(Int64).new(0)
      @stat_misses = Atomic(Int64).new(0)
      @stat_revalidations = Atomic(Int64).new(0)
      @stat_errors = Atomic(Int64).new(0)
      @stat_bytes = Atomic(Int64).new(0)
      @stat_tunnels = Atomic(Int64).new(0)
    end

    # Returns cumulative counters since the process started.
    #
    # - *hits* — requests served directly from cache
    # - *misses* — requests that triggered an upstream download
    # - *revalidations* — index-file requests answered with 304 Not Modified
    # - *errors* — requests that resulted in a 4xx or 5xx response
    # - *bytes* — total bytes written to clients
    # - *tunnels* — CONNECT tunnels successfully established (HTTPS passthrough)
    def stats : NamedTuple(hits: Int64, misses: Int64, revalidations: Int64, errors: Int64, bytes: Int64, tunnels: Int64)
      {
        hits:          @stat_hits.get,
        misses:        @stat_misses.get,
        revalidations: @stat_revalidations.get,
        errors:        @stat_errors.get,
        bytes:         @stat_bytes.get,
        tunnels:       @stat_tunnels.get,
      }
    end

    # Closes the pooled upstream connections that have been idle past their
    # keep-alive. Meant to be called periodically.
    def sweep_idle_connections : Nil
      @pool.sweep
    end

    # Handles a single HTTP request from an APT client.
    #
    # Tunnels CONNECT; rejects non-GET/HEAD methods, path traversal,
    # unmappable URLs and forbidden targets with appropriate 4xx codes. For
    # valid requests, ensures the resource is cached (downloading it if
    # necessary) and streams it to the client. Returns 502 on upstream failure
    # or cache loss.
    def handle(ctx : HTTP::Server::Context) : Nil
      started_at = Time.instant
      req = ctx.request
      res = ctx.response

      if req.method == "CONNECT"
        tunnel(req, res, started_at)
        return
      end

      # Liveness probe, answered before anything is resolved, counted or
      # logged. It has to be free of side effects: Docker's HEALTHCHECK fires
      # it every 30s, and booked as a regular request it would resolve to
      # nothing and book ~2880 invented errors a day into the counters, into
      # /api/metrics and into the access log.
      #
      # Matched on the raw resource, not on the path: `GET http://mirror/_health`
      # is a proxied request for a mirror that happens to publish that path,
      # and must keep being proxied rather than shadowed by the probe.
      if req.resource == HEALTH_PATH && req.method.in?("GET", "HEAD")
        res.status = HTTP::Status::OK
        res.content_type = "text/plain"
        res.puts "ok" unless req.method == "HEAD"
        return
      end

      unless req.method.in?("GET", "HEAD")
        reject(req, res, HTTP::Status::METHOD_NOT_ALLOWED, nil, req.resource, started_at)
        return
      end

      resolved = resolve(req)
      unless resolved
        reject(req, res, HTTP::Status::BAD_REQUEST, "cannot map request to a mirror", req.resource, started_at)
        return
      end
      key, upstream, trusted = resolved

      # coarse but effective path traversal guard
      if key.includes?("..")
        reject(req, res, HTTP::Status::BAD_REQUEST, "invalid path", key, started_at)
        return
      end

      # Keys the cache cannot hold as a file of their own are relayed from
      # upstream without touching it.
      if uncacheable?(key)
        relay(req, res, key: key, upstream: upstream, trusted: trusted, started_at: started_at)
        return
      end

      serve_cached(req, res, key: key, upstream: upstream, trusted: trusted, started_at: started_at)
    end

    # Answers *status* with an optional one-line *message* and books the
    # request as an error under *label* (the resource, or the key once known).
    private def reject(req : HTTP::Request, res : HTTP::Server::Response, status : HTTP::Status,
                       message : String?, label : String, started_at : Time::Instant) : Nil
      res.status = status
      res.puts message if message
      log_access(req.method, label, status.code, started_at, CacheResult::Error, client: req.remote_address)
    end

    # Ensures *key* is cached, then streams it to the client.
    private def serve_cached(req : HTTP::Request, res : HTTP::Server::Response, key : String,
                             upstream : String, trusted : Bool, started_at : Time::Instant) : Nil
      cache_result, error_status, file = fetch_and_open(key, upstream, trusted)

      unless file
        message = error_status == 403 ? "forbidden by upstream or by the proxy target policy" : "upstream fetch failed"
        message = "cache entry lost, please retry" unless cache_result.error?
        reject(req, res, HTTP::Status.new(error_status), message, key, started_at)
        return
      end

      bytes = serve(file, res, head_only: req.method == "HEAD",
        range: req.headers["Range"]?, conditional: req.headers.has_key?("If-Range"))
      # Eviction sorts on the mtime: a served package is a used package.
      @cache.mark_used(key) if cache_result.hit? && immutable?(key)
      result = res.status.range_not_satisfiable? ? CacheResult::Error : cache_result
      log_access(req.method, key, res.status_code, started_at, result, bytes: bytes, client: req.remote_address)
    end

    # Ensures *key* is cached and opens its file. Returns
    # {result, client_status, file}; *file* is `nil` on failure, with
    # *client_status* telling the client why.
    #
    # The file can disappear from disk after it was cached in memory — the
    # cache directory was cleared, or eviction ran between the check and the
    # open. Nothing has been sent at that point: the stale in-memory state is
    # dropped and the file fetched again within the same request, once. If it
    # is still missing after that, the result is not an error but the file is
    # `nil`, and the status is 502.
    private def fetch_and_open(key : String, upstream : String, trusted : Bool) : {CacheResult, Int32, File?}
      2.times do
        cache_result, error_status = ensure_cached(key, upstream, trusted)
        return {cache_result, error_status, nil} if cache_result.error?
        if file = open_cached(key)
          return {cache_result, error_status, file}
        end
        @cache.invalidate(key)
      end
      {CacheResult::Miss, 502, nil}
    end

    # Returns `true` for a key that must never become a cache file:
    # - a sidecar name, which would read or overwrite the sidecar of another
    #   entry;
    # - the name of a temporary download file, which scans skip and startup
    #   deletes;
    # - a path ending with `/`, or one that is already a directory of the
    #   cache: what upstream serves there is a directory index, and the name
    #   is needed as a directory for the entries below it.
    private def uncacheable?(key : String) : Bool
      Cache.sidecar?(key) || Cache.temp?(key) || key.ends_with?('/') || @cache.directory?(key)
    end

    # Opens the cached file of *key*, or returns `nil` when it is gone.
    private def open_cached(key : String) : File?
      @cache.open(key)
    rescue File::Error
      nil
    end

    # Streams *upstream* to the client without reading or writing the cache.
    #
    # Used for the keys `uncacheable?` names. Counted as a miss (the bytes came
    # from upstream); upstream error codes are passed through with the body
    # left unread, as in `download`.
    private def relay(req : HTTP::Request, res : HTTP::Server::Response, key : String, upstream : String, trusted : Bool, started_at : Time::Instant) : Nil
      status = 502
      bytes = 0_i64
      streaming = false
      truncated = false
      fetch(upstream, HTTP::Headers{"User-Agent" => USER_AGENT}, trusted: trusted) do |response|
        status = client_status(response.status_code)
        res.status = HTTP::Status.new(status)
        next false unless status == 200
        res.content_type = response.headers["Content-Type"]? || "application/octet-stream"
        expected = response.headers["Content-Length"]?.try(&.to_i64?)
        res.content_length = expected if expected
        # HEAD: the body is left unread and the connection discarded.
        next false if req.method == "HEAD"
        streaming = true
        bytes = IO.copy(response.body_io, res)
        # IO::Sized stops at EOF without raising: a short body only shows up
        # here. The status line is already sent, so it can only be booked as an
        # error and the connection discarded.
        truncated = !expected.nil? && bytes != expected
        if truncated
          Log.error { "incomplete relay #{loggable(upstream)}: expected #{expected} B, got #{bytes} B" }
          # HTTP::Server reads this after the handler returns, even with the
          # headers already sent: without it the client connection is kept
          # alive and the client waits forever for the missing bytes.
          res.headers["Connection"] = "close"
        end
        !truncated
      end
      result = status == 200 && !truncated ? CacheResult::Miss : CacheResult::Error
      log_access(req.method, key, status, started_at, result, bytes: bytes, client: req.remote_address)
    rescue ex
      status = relay_failure(res, key, upstream, ex, streaming == true)
      log_access(req.method, key, status, started_at, CacheResult::Error, bytes: bytes, client: req.remote_address)
    end

    # Shapes the response of a relay that raised and returns the status to
    # book: 403 for a refused target, 502 otherwise.
    private def relay_failure(res : HTTP::Server::Response, key : String, upstream : String,
                              ex : Exception, streaming : Bool) : Int32
      if ex.is_a?(ForbiddenTarget)
        Log.warn { "relay refused: #{key} — #{ex.message}" }
        res.status = HTTP::Status::FORBIDDEN
        res.puts "target not allowed"
        return 403
      end
      Log.warn { "relay failed: #{loggable(upstream)} — #{ex.message}" }
      # Once the body has started the status line is already on the wire: the
      # response can only be cut short, by closing the client connection.
      if streaming
        res.headers["Connection"] = "close"
      else
        res.status = HTTP::Status::BAD_GATEWAY
      end
      502
    end

    # Maps the request (any mode) to {cache key, upstream URL, trusted}.
    # *trusted* is `true` when the upstream comes from the remap table, i.e.
    # from the configuration rather than from the client.
    private def resolve(req : HTTP::Request) : {String, String, Bool}?
      resource = req.resource

      if resource.starts_with?("http://") || resource.starts_with?("https://")
        resolve_absolute(resource)
      else
        resolve_host_in_path(req)
      end
    end

    # Absolute form (proxy mode): the resource IS the upstream URL.
    private def resolve_absolute(resource : String) : {String, String, Bool}?
      uri = URI.parse(resource)
      host = uri.host
      return nil unless host
      path = uri.path
      return nil if path.empty?

      port = uri.port
      port_suffix = if port && port != URI.default_port(uri.scheme || "http")
                      ":#{port}"
                    else
                      ""
                    end
      upstream, remapped = apply_remap(resource)
      {"#{host}#{port_suffix}#{path}", upstream, remapped}
    end

    # Origin form (host-in-path mode): first path segment is the upstream host.
    private def resolve_host_in_path(req : HTTP::Request) : {String, String, Bool}?
      key = req.path.lchop('/')
      host, _, rest = key.partition('/')
      return nil if host.empty? || rest.empty?
      # Carry the query string upstream (e.g. signed mirror URLs); the cache
      # key stays query-free, matching the absolute-form branch above.
      upstream = "http://#{host}/#{rest}"
      if (q = req.query) && !q.empty?
        upstream += "?#{q}"
      end
      upstream, remapped = apply_remap(upstream)
      {key, upstream, remapped}
    end

    # Applies the host remapping table to *upstream_url*, returning the URL to
    # fetch and whether a remap was applied.
    # The cache key is built before this call and is never remapped, so the
    # cache remains valid even if the configured mirror changes.
    private def apply_remap(upstream_url : String) : {String, Bool}
      return {upstream_url, false} if @remaps.empty?
      uri = URI.parse(upstream_url)
      host = uri.host || return {upstream_url, false}
      target = @remaps[host]? || return {upstream_url, false}
      if target.starts_with?("http://") || target.starts_with?("https://")
        # Full URL target: replace scheme, host, port, and optionally prepend path.
        # e.g. "docker" → "https://download.docker.com/linux/debian" prepends
        # "/linux/debian" so /dists/... becomes /linux/debian/dists/...
        t = URI.parse(target)
        uri.scheme = t.scheme
        uri.host = t.host
        uri.port = t.port
        prefix = t.path.rstrip("/")
        uri.path = prefix + uri.path unless prefix.empty?
      else
        # Bare host or host:port target.
        bare_host, _, bare_port = target.partition(":")
        uri.host = bare_host
        uri.port = bare_port.empty? ? nil : bare_port.to_i?
      end
      {uri.to_s, true}
    end

    # Raises `ForbiddenTarget` when *uri* points at a local address and local
    # targets are not allowed. Called for every hop of a fetch, so a redirect
    # cannot lead where a direct request could not go.
    #
    # The check resolves the name; the connection resolves it again. A name
    # whose answer changes between the two (DNS rebinding) is not caught here:
    # the admin server's own authentication is what covers that residue.
    private def check_target!(uri : URI) : Nil
      return if @allow_local_targets
      host = uri.host || raise ForbiddenTarget.new("no host in #{uri}")
      port = uri.port || URI.default_port(uri.scheme || "http") || 80
      if AptLarder.local_target?(host, port)
        raise ForbiddenTarget.new("#{host} is a local address (set allow_local_targets to permit it)")
      end
    end

    # Delegates to `AptLarder.immutable?` — see helpers.cr for the heuristic.
    private def immutable?(key : String) : Bool
      AptLarder.immutable?(key)
    end

    # Ensures *key* is in the cache, using `SingleFlight` to deduplicate
    # concurrent requests. Returns the outcome for the calling fiber.
    # Returns {result, client_status} where client_status is the HTTP status
    # to return to the client on error (upstream 4xx passed through, 502 for
    # gateway-level failures like timeouts or connection errors).
    private def ensure_cached(key : String, upstream : String, trusted : Bool) : {CacheResult, Int32}
      # Fast O(1) pre-check only — the expensive integrity verification and
      # repair (`cached_and_valid?`) is deferred to the single-flight leader so
      # a burst of concurrent requests hashes the file at most once.
      return {CacheResult::Hit, 200} if cached_fresh?(key)

      # The result holder of the flight in progress for this key, if any. It
      # is read before blocking on the flight: a waiter then holds the holder
      # of the very flight it joins, whatever starts on the same key afterwards.
      joined = @sf_refs_mutex.synchronize { @sf_refs[key]? }

      own = nil
      @sf.run(key) do
        ref = ResultRef.new
        own = ref
        @sf_refs_mutex.synchronize { @sf_refs[key] = ref }
        begin
          ref.value, ref.status = cached_and_valid?(key) ? {CacheResult::Hit, 200} : download(key, upstream, trusted)
        ensure
          @sf_refs_mutex.synchronize { @sf_refs.delete(key) if @sf_refs[key]?.same?(ref) }
        end
      end

      # Leader: its own holder. Waiter: the one of the flight it joined; the
      # disk is only consulted when that flight left no result (it raised, or
      # it started in the instant between the lookup above and `run`).
      ref = own || joined
      result = ref.try(&.value) || (!own && @cache.exists?(key) ? CacheResult::Miss : CacheResult::Error)
      {result, ref.try(&.status) || 502}
    end

    # O(1) pre-check used before entering the single-flight: returns `true` only
    # when the entry can be served without any disk hashing. Immutable entries
    # qualify only once their SHA256 has already been verified this session;
    # index entries qualify while still within the TTL window. Anything else
    # falls through to the single-flight, where `cached_and_valid?` performs the
    # heavy verification/repair exactly once per key.
    private def cached_fresh?(key : String) : Bool
      if immutable?(key)
        @cache.verified?(key)
      else
        @cache.fresh?(key, @index_ttl_span)
      end
    end

    # Returns `true` if the cached file is fresh enough to serve without
    # contacting upstream. For immutable files this also verifies SHA256
    # on the first call per session and invalidates corrupt entries.
    private def cached_and_valid?(key : String) : Bool
      if immutable?(key)
        return false unless @cache.exists?(key)
        # Verify integrity on first serve of this session; @verified makes
        # subsequent calls O(1). Corrupt files are invalidated immediately
        # so the next ensure_cached call triggers a fresh download.
        unless @cache.valid?(key)
          @cache.invalidate(key)
          return false
        end
        true
      else
        @cache.fresh?(key, @index_ttl_span)
      end
    end

    # Adds the conditional headers that revalidate an index file we already have.
    #
    # The validators upstream sent are replayed verbatim: the local mtime is our
    # own clock (bumped on every 304), so a 304 from a mirror that had not synced
    # yet would push it past the next upstream Last-Modified and pin the stale
    # file forever. Entries without stored validators get a plain GET, and so
    # does an orphaned sidecar whose data file is gone (a 304 would then have
    # nothing to serve).
    #
    # The ETag is only a fallback: RFC 9110 lets If-None-Match override
    # If-Modified-Since, and a round-robin node still on the previous file has
    # another ETag, so it would answer 200 with that older file and roll the
    # cache back. If-Modified-Since alone gets a 304 from that node instead.
    private def add_revalidation_headers(headers : HTTP::Headers, key : String) : Nil
      return unless @cache.modification_time?(key)
      return unless validators = @cache.validators(key)
      if last_modified = validators.last_modified
        headers["If-Modified-Since"] = last_modified
      elsif etag = validators.etag
        headers["If-None-Match"] = etag
      end
    end

    # Fetches *upstream*, stores the response in the cache, and returns
    # {result, client_status}. Content-Length mismatches are treated as errors.
    # Upstream 4xx/5xx codes are passed through so APT sees the real reason.
    private def download(key : String, upstream : String, trusted : Bool) : {CacheResult, Int32}
      is_immutable = immutable?(key)
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}
      add_revalidation_headers(headers, key) unless is_immutable

      result = {CacheResult::Error, 502}
      fetch(upstream, headers, trusted: trusted) do |response|
        case status = response.status_code
        when 200
          expected = response.headers["Content-Length"]?.try(&.to_i64?)
          # Immutable entries are never revalidated, so they keep no validators.
          @cache.store(key, response.body_io,
            last_modified: is_immutable ? nil : response.headers["Last-Modified"]?,
            etag: is_immutable ? nil : response.headers["ETag"]?)
          stored = @cache.size(key)
          if expected && stored != expected
            @cache.invalidate(key)
            Log.error { "incomplete download #{loggable(upstream)}: expected #{expected} B, got #{stored} B" }
            result = {CacheResult::Error, 502}
            # body not fully consumed — the connection stream is dirty, discard it
            false
          else
            Log.debug { "fetched #{loggable(upstream)} -> #{format_bytes(stored)}" }
            result = {CacheResult::Miss, 200}
            # body fully consumed by store — connection is clean
            true
          end
        when 304
          # refresh the freshness window
          @cache.touch(key) if !is_immutable
          Log.debug { "revalidated #{loggable(upstream)}" }
          result = {CacheResult::Revalidated, 200}
          # no body — connection is clean
          true
        else
          Log.warn { "upstream #{status} for #{loggable(upstream)}" }
          result = stale_or(key, {CacheResult::Error, client_status(status)}, outage: status >= 500)
          # The error body is left unread on purpose: an upstream error page can
          # be arbitrarily large or slow, so draining it to save one handshake is
          # a bad trade. Returning false discards the connection instead.
          false
        end
      end
      result
    rescue ex : ForbiddenTarget
      Log.warn { "fetch refused: #{key} — #{ex.message}" }
      {CacheResult::Error, 403}
    rescue ex
      Log.warn { "fetch failed: #{loggable(upstream)} — #{ex.message}" }
      stale_or(key, {CacheResult::Error, 502}, outage: true)
    end

    # Status to hand to the client for an upstream status that is neither 200
    # nor 304. Client and server errors are passed through so APT sees the
    # real reason; anything else (206, 203, a 3xx without Location…) is not an
    # answer the proxy can turn into a file and becomes 502.
    private def client_status(upstream_status : Int32) : Int32
      upstream_status == 200 || upstream_status >= 400 ? upstream_status : 502
    end

    # Returns *failure*, unless upstream is having an *outage* (unreachable,
    # timed out, 5xx) and an index file is still in the cache: the stale copy
    # is then served as a hit. `apt update` keeps working through a mirror
    # outage, with the packages it lists already cached. The mtime is left
    # alone, so the next request tries upstream again.
    #
    # Immutable entries never get here with a copy on disk, and a 4xx is an
    # answer rather than an outage (the file is gone upstream).
    private def stale_or(key : String, failure : {CacheResult, Int32}, outage : Bool) : {CacheResult, Int32}
      return failure if !outage || immutable?(key) || !@cache.exists?(key)
      Log.warn { "upstream unavailable, serving the stale copy of #{key}" }
      {CacheResult::Hit, 200}
    end

    # *url* without its query string and credentials — the two places a
    # secret can sit (signed mirror URLs, `user:password@host`) — for log lines.
    private def loggable(url : String) : String
      uri = URI.parse(url)
      uri.query = nil
      uri.user = nil
      uri.password = nil
      uri.to_s
    rescue URI::Error
      url.partition('?')[0]
    end

    # GET with redirect following and per-host connection reuse.
    #
    # Mirrors commonly redirect http → https. HTTP::Client negotiates TLS
    # automatically when the URL scheme is https://, so no special TLS handling
    # is needed here. Runtime requirement: ca-certificates must be present for
    # certificate verification to succeed.
    #
    # 304 (Not Modified) falls in the 3xx range but is NOT a redirect — we
    # match redirect status codes explicitly to avoid following it.
    #
    # Every hop goes through `check_target!`, except the first one when
    # *trusted* (the URL comes from the remap table). Raises `ForbiddenTarget`
    # on a refused hop.
    private def fetch(url : String, headers : HTTP::Headers, trusted : Bool = false, &) : Nil
      current = url
      redirects = 0

      loop do
        follow = nil
        uri = URI.parse(current)
        check_target!(uri) unless trusted && redirects == 0

        checked_get(uri, headers) do |response|
          if response.status_code.in?(301, 302, 303, 307, 308) &&
             (location = response.headers["Location"]?)
            follow = URI.parse(current).resolve(location).to_s
            # Drain the redirect body so the connection can be reused. It must
            # go through body_io: in the block form of HTTP::Client#get the
            # response carries body_io and `body` is nil, so `response.body`
            # returns "" without reading a single byte off the socket. A 301
            # with an HTML body (nginx http->https) would then be checked back
            # into the pool still holding it, and the next request on that
            # connection would parse the HTML as a status line.
            response.body_io?.try(&.skip_to_end)
            true
          else
            # propagates the Bool returned by download's block
            yield response
          end
        end

        break unless follow
        raise "too many redirects starting from #{loggable(url)}" if redirects >= @max_redirects
        redirects += 1
        Log.debug { "redirect #{loggable(current)} -> #{loggable(follow)}" }
        current = follow
      end
    end

    # Borrows a connection from the pool, runs the block, returns the connection.
    #
    # On a connection taken from the pool, any failure BEFORE the body starts
    # is retried once on a fresh connection. The cut-off is `body_started`, not
    # the exception class: everything raised up to that point comes from
    # sending or parsing the response head — all symptoms of a pooled
    # connection gone bad (closed by the peer, or left holding bytes from a
    # previous exchange), and all replayable since the request is a GET. A dead
    # socket surfaces as an IO::Error, an unparseable response head as a bare
    # Exception; both must be retried.
    #
    # A connection opened for this very request is not retried: its failure
    # says something about upstream, and a second attempt would only double
    # the wait (two connect timeouts) before the client gets its 502.
    #
    # Once the body has started, the block owns the stream and its failures
    # (disk full while storing, etc.) do not originate upstream — those are
    # re-raised as-is.
    private def checked_get(uri : URI, headers : HTTP::Headers, &) : Nil
      pooled = @pool.checkout?(uri)
      retried = pooled.nil?
      client = pooled || HTTP::Client.new(uri)
      configure_client(client)
      loop do
        body_started = false
        reuse = false
        begin
          # request_target preserves the query string (e.g. signed CDN URLs
          # like ...?token=abc reached via a redirect); uri.path would drop it.
          client.get(uri.request_target, headers: headers) do |response|
            body_started = true
            # block returns true if the connection is safe to reuse
            reuse = yield response
          end
          reuse ? @pool.checkin(uri, client) : @pool.discard(client)
          break
        rescue ex
          @pool.discard(client)
          raise ex if retried || body_started
          retried = true
          client = HTTP::Client.new(uri)
          configure_client(client)
        end
      end
    end

    # Applies connect and read timeouts to *client*.
    private def configure_client(client : HTTP::Client) : Nil
      client.connect_timeout = @connect_timeout
      client.read_timeout = @read_timeout
    end

    # Streams the cached *file* to *res* and closes it. Handles `Range`
    # requests (206, or 416 when the range lies beyond the file) and `HEAD`
    # (headers only). Returns the number of bytes written.
    #
    # *conditional* is `true` when the request carries `If-Range`. The proxy
    # keeps nothing to compare that validator with on the client's behalf, so
    # the range is ignored and the whole file is sent: the one answer that can
    # never splice the tail of a new file onto the head of an old one.
    private def serve(file : File, res : HTTP::Server::Response, head_only : Bool,
                      range : String? = nil, conditional : Bool = false) : Int64
      total = file.size
      res.content_type = "application/octet-stream"
      kind, first, last = range && !conditional ? parse_range(range, total) : WHOLE_FILE

      if kind.unsatisfiable?
        res.status = HTTP::Status::RANGE_NOT_SATISFIABLE
        res.headers["Content-Range"] = "bytes */#{total}"
        res.content_length = 0
        0_i64
      elsif kind.partial?
        length = last - first + 1
        res.status = HTTP::Status::PARTIAL_CONTENT
        res.headers["Content-Range"] = "bytes #{first}-#{last}/#{total}"
        res.content_length = length
        # HEAD sets headers but writes no body — report 0 bytes written.
        return 0_i64 if head_only
        file.seek(first)
        buf = Bytes.new(COPY_BUFFER_SIZE)
        remaining = length
        while remaining > 0
          n = file.read(buf[0, [remaining, COPY_BUFFER_SIZE.to_i64].min.to_i32])
          break if n == 0
          res.write(buf[0, n])
          remaining -= n
        end
        length
      else
        res.content_length = total
        # HEAD sets headers but writes no body — report 0 bytes written.
        return 0_i64 if head_only
        buffered_copy(file, res)
        total
      end
    ensure
      file.close
    end

    # Parses a `Range: bytes=first-last` header against *total* file size.
    #
    # Returns the kind of answer it calls for and, for `Partial`, the bounds
    # clamped to the file. A header that is not a single well-formed byte range
    # (other unit, several ranges, `first` after `last`, garbage) is `Whole`:
    # RFC 9110 lets a server ignore a Range it cannot or will not honour. A
    # well-formed range that starts at or beyond the end of the file, or a
    # zero-length suffix, is `Unsatisfiable`.
    private def parse_range(header : String, total : Int64) : {RangeKind, Int64, Int64}
      return WHOLE_FILE unless header.starts_with?("bytes=")
      spec = header[6..]
      dash = spec.index('-') || return WHOLE_FILE
      start_str = spec[0, dash]
      end_str = spec[dash + 1..]
      start_str.empty? ? parse_suffix_range(end_str, total) : parse_bounded_range(start_str, end_str, total)
    end

    # `bytes=-N`: the last N bytes of the file.
    private def parse_suffix_range(length : String, total : Int64) : {RangeKind, Int64, Int64}
      suffix = length.to_i64?
      return WHOLE_FILE unless suffix && suffix >= 0
      return UNSATISFIABLE if suffix == 0 || total == 0
      {RangeKind::Partial, [total - suffix, 0_i64].max, total - 1}
    end

    # `bytes=first-last` and `bytes=first-`.
    private def parse_bounded_range(start_str : String, end_str : String, total : Int64) : {RangeKind, Int64, Int64}
      first = start_str.to_i64?
      return WHOLE_FILE unless first && first >= 0
      last = total - 1
      unless end_str.empty?
        given = end_str.to_i64?
        return WHOLE_FILE unless given && given >= first
        last = [given, last].min
      end
      return UNSATISFIABLE if first >= total
      {RangeKind::Partial, first, last}
    end

    # Opens a transparent TCP tunnel for CONNECT requests.
    #
    # The proxy connects to the target host:port, sends HTTP 200, then relays
    # bytes in both directions until either side closes. HTTPS traffic is not
    # inspected or cached — TLS is negotiated end-to-end between APT and the
    # upstream mirror.
    #
    # Only ports listed in `connect_ports` can be tunnelled to, and local
    # addresses are refused unless `allow_local_targets` is set: without both
    # limits the proxy is a TCP relay into the loopback interface and the
    # internal network of its host.
    private def tunnel(req : HTTP::Request, res : HTTP::Server::Response, started_at : Time::Instant) : Nil
      # Parses host:port, including bracketed IPv6 literals — see helpers.cr.
      host, port = AptLarder.parse_connect_target(req.resource)
      upstream = open_tunnel_upstream(host, port)

      # upgrade() writes HTTP headers (status 200) and yields the raw client socket.
      # The socket has sync=false (HTTP::Server default) so we must flush after
      # each write — otherwise TLS handshake bytes sit in the buffer and the
      # handshake times out ("Error in the push function").
      res.headers.delete("Content-Type")
      res.upgrade do |client|
        # Buffered for 2 so both relay fibers can report completion without a
        # reader: we only need the first to know the tunnel is done, but the
        # second must not block forever on send (which would leak the fiber).
        done = Channel(Nil).new(2)
        buf = Bytes.new(16 * 1024)
        spawn do
          loop do
            n = upstream.read(buf) rescue break
            break if n == 0
            client.write(buf[0, n]) rescue break
            client.flush rescue break
          end
          done.send(nil)
        end
        spawn { IO.copy(client, upstream) rescue nil; done.send(nil) }
        done.receive
        upstream.close rescue nil
      end
      @stat_tunnels.add(1)
      Log.info { "#{client_ip(req.remote_address)}200 TUNNEL CONNECT #{req.resource}" }
    rescue ex
      status, message = tunnel_failure(ex)
      reject(req, res, status, message, req.resource, started_at)
    end

    # Applies the target policy to *host*:*port* and returns the connected
    # upstream socket. Raises `ForbiddenTarget` when the policy refuses.
    private def open_tunnel_upstream(host : String, port : Int32) : TCPSocket
      unless @connect_ports.includes?(port)
        raise ForbiddenTarget.new("CONNECT to port #{port} is not allowed (see connect_ports)")
      end
      # Refused before dialling, so the answer says nothing about which local
      # ports are open.
      if !@allow_local_targets && AptLarder.local_target?(host, port)
        raise ForbiddenTarget.new("#{host} is a local address (set allow_local_targets to permit it)")
      end

      upstream = TCPSocket.new(host, port, connect_timeout: @connect_timeout)
      # On some platforms (seen on macOS 27 with Crystal 1.20.3) a refused
      # connect returns without raising and only fails on the first write,
      # after the 200 has already been sent. getpeername fails on a socket that
      # never connected, so asking for the peer surfaces the refusal here.
      begin
        peer = upstream.remote_address
        # The name was resolved a second time to connect: judge the address
        # the socket actually reached, which no DNS answer can change anymore.
        if !@allow_local_targets && AptLarder.local_address?(peer)
          raise ForbiddenTarget.new("#{host} connected to a local address")
        end
      rescue ex
        # Close it here: the caller only answers 403 or 502, and the socket
        # would otherwise hold a file descriptor until the GC finalizes it.
        upstream.close rescue nil
        raise ex
      end
      upstream.read_timeout = @read_timeout
      upstream
    end

    # Status and one-line body for a tunnel that could not be opened: 400 for
    # an unparseable CONNECT authority, 403 for a target the policy refuses,
    # 502 when upstream cannot be reached.
    private def tunnel_failure(ex : Exception) : {HTTP::Status, String}
      case ex
      when ArgumentError   then {HTTP::Status::BAD_REQUEST, "invalid CONNECT target: #{ex.message}"}
      when ForbiddenTarget then {HTTP::Status::FORBIDDEN, "tunnel refused: #{ex.message}"}
      else                      {HTTP::Status::BAD_GATEWAY, "tunnel failed: #{ex.message}"}
      end
    end

    # Copies *file* to *res* in `COPY_BUFFER_SIZE` chunks.
    # Prefer `sendfile(2)` once Crystal 1.21 ships (see PR #16665).
    private def buffered_copy(file : File, res : HTTP::Server::Response) : Nil
      buf = Bytes.new(COPY_BUFFER_SIZE)
      loop do
        n = file.read(buf)
        break if n == 0
        res.write(buf[0, n])
      end
    end

    # Increments the appropriate stat counter and emits one access log line
    # (suppressed for HIT/REVAL in quiet mode).
    private def log_access(method : String, key : String, status : Int32, started_at : Time::Instant, cache_result : CacheResult, bytes : Int64? = nil, client : Socket::Address? = nil) : Nil
      case cache_result
      in .hit?         then @stat_hits.add(1)
      in .miss?        then @stat_misses.add(1)
      in .revalidated? then @stat_revalidations.add(1)
      in .error?       then @stat_errors.add(1)
      end
      @stat_bytes.add(bytes) if bytes
      return if @quiet && (cache_result.hit? || cache_result.revalidated?)
      elapsed_ms = started_at.elapsed.total_milliseconds
      elapsed = elapsed_ms >= 1000 ? "#{(elapsed_ms / 1000).round(1)}s" : "#{elapsed_ms.round}ms"
      tag = case cache_result
            in .hit?         then "HIT  "
            in .miss?        then "MISS "
            in .revalidated? then "REVAL"
            in .error?       then status < 500 ? "ERR  " : "FAIL "
            end
      size = bytes ? " #{format_bytes(bytes)}" : ""
      Log.info { "#{client_ip(client)}#{status} #{tag} #{method} #{key}#{size} (#{elapsed})" }
    end

    # Delegates to `AptLarder.format_bytes` — see helpers.cr.
    private def format_bytes(n : Int64) : String
      AptLarder.format_bytes(n)
    end

    # Returns `"[ip] "` when *addr* is an IP address, empty string otherwise.
    private def client_ip(addr : Socket::Address?) : String
      return "" unless addr.is_a?(Socket::IPAddress)
      "[#{addr.address}] "
    end
  end
end
