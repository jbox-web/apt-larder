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

    private enum CacheResult
      Hit
      Miss
      Revalidated
      Error
    end

    # Carries the leader's CacheResult to all concurrent waiters for the same key.
    # The leader writes before channel.close; waiters read after — safe under
    # Crystal's cooperative scheduler (no yield between write and close).
    private class ResultRef
      property value : CacheResult?

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
    def initialize(
      @cache : Cache,
      @sf : SingleFlight,
      @max_redirects : Int32,
      index_ttl : Int32,
      connect_timeout : Int32,
      read_timeout : Int32,
      @quiet : Bool = false,
      @remaps : Hash(String, String) = {} of String => String,
    )
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
    end

    # Returns cumulative counters since the process started.
    #
    # - *hits* — requests served directly from cache
    # - *misses* — requests that triggered an upstream download
    # - *revalidations* — index-file requests answered with 304 Not Modified
    # - *errors* — requests that resulted in a 4xx or 5xx response
    # - *bytes* — total bytes written to clients
    def stats : NamedTuple(hits: Int64, misses: Int64, revalidations: Int64, errors: Int64, bytes: Int64)
      {
        hits:          @stat_hits.get,
        misses:        @stat_misses.get,
        revalidations: @stat_revalidations.get,
        errors:        @stat_errors.get,
        bytes:         @stat_bytes.get,
      }
    end

    # Handles a single HTTP request from an APT client.
    #
    # Rejects CONNECT, non-GET/HEAD methods, path traversal, and unmappable
    # URLs with appropriate 4xx codes. For valid requests, ensures the
    # resource is cached (downloading it if necessary) and streams it to the
    # client. Returns 502 on upstream failure or cache loss.
    def handle(ctx : HTTP::Server::Context) : Nil
      started_at = Time.monotonic
      req = ctx.request
      res = ctx.response

      if req.method == "CONNECT"
        tunnel(req, res, started_at)
        return
      end

      unless req.method.in?("GET", "HEAD")
        res.status = HTTP::Status::METHOD_NOT_ALLOWED
        log_access(req.method, req.resource, res.status_code, started_at, CacheResult::Error, client: req.remote_address)
        return
      end

      resolved = resolve(req)
      unless resolved
        res.status = HTTP::Status::BAD_REQUEST
        res.puts "cannot map request to a mirror"
        log_access(req.method, req.resource, res.status_code, started_at, CacheResult::Error, client: req.remote_address)
        return
      end
      key, upstream = resolved

      # coarse but effective path traversal guard
      if key.includes?("..")
        res.status = HTTP::Status::BAD_REQUEST
        res.puts "invalid path"
        log_access(req.method, key, res.status_code, started_at, CacheResult::Error, client: req.remote_address)
        return
      end

      cache_result = ensure_cached(key, upstream)

      if cache_result.error?
        res.status = HTTP::Status::BAD_GATEWAY
        res.puts "upstream fetch failed"
        log_access(req.method, key, res.status_code, started_at, CacheResult::Error, client: req.remote_address)
        return
      end

      begin
        bytes = serve(key, res, head_only: req.method == "HEAD", range: req.headers["Range"]?)
      rescue File::Error
        # The file disappeared from disk after it was cached in memory — most
        # likely the cache directory was cleared while the server was running.
        # Invalidate all in-memory state so the next request re-downloads.
        @cache.invalidate(key)
        res.status = HTTP::Status::BAD_GATEWAY
        res.puts "cache entry lost, please retry"
        log_access(req.method, key, 502, started_at, CacheResult::Error, client: req.remote_address)
        return
      end
      log_access(req.method, key, res.status_code, started_at, cache_result, bytes: bytes, client: req.remote_address)
    end

    # Maps the request (any mode) to {cache key, upstream URL}.
    private def resolve(req : HTTP::Request) : {String, String}?
      resource = req.resource

      if resource.starts_with?("http://") || resource.starts_with?("https://")
        # Absolute form (proxy mode): the resource IS the upstream URL.
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
        {"#{host}#{port_suffix}#{path}", apply_remap(resource)}
      else
        # Origin form (host-in-path mode): first path segment is the upstream host.
        key = req.path.lchop('/')
        host, _, rest = key.partition('/')
        return nil if host.empty? || rest.empty?
        {key, apply_remap("http://#{host}/#{rest}")}
      end
    end

    # Applies the host remapping table to *upstream_url*.
    # The cache key is built before this call and is never remapped, so the
    # cache remains valid even if the configured mirror changes.
    private def apply_remap(upstream_url : String) : String
      return upstream_url if @remaps.empty?
      uri = URI.parse(upstream_url)
      host = uri.host || return upstream_url
      target = @remaps[host]? || return upstream_url
      if target.starts_with?("http://") || target.starts_with?("https://")
        # Full URL target: replace scheme, host and port.
        t = URI.parse(target)
        uri.scheme = t.scheme
        uri.host = t.host
        uri.port = t.port
      else
        # Bare host or host:port target.
        bare_host, _, bare_port = target.partition(":")
        uri.host = bare_host
        uri.port = bare_port.empty? ? nil : bare_port.to_i?
      end
      uri.to_s
    end

    # Delegates to `AptLarder.immutable?` — see helpers.cr for the heuristic.
    private def immutable?(key : String) : Bool
      AptLarder.immutable?(key)
    end

    # Ensures *key* is in the cache, using `SingleFlight` to deduplicate
    # concurrent requests. Returns the outcome for the calling fiber.
    private def ensure_cached(key : String, upstream : String) : CacheResult
      return CacheResult::Hit if cached_and_valid?(key)

      # All concurrent fibers for the same key share the same ResultRef object.
      # Each fiber acquires it here (before blocking), so it remains accessible
      # even after it is removed from @sf_refs.
      ref = @sf_refs_mutex.synchronize { @sf_refs[key] ||= ResultRef.new }

      was_leader = false
      @sf.run(key) do
        was_leader = true
        ref.value = cached_and_valid?(key) ? CacheResult::Hit : download(key, upstream)
      end

      @sf_refs_mutex.synchronize { @sf_refs.delete(key) }
      ref.value || (was_leader ? CacheResult::Error : (@cache.exists?(key) ? CacheResult::Miss : CacheResult::Error))
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

    # Fetches *upstream*, stores the response in the cache, and returns the
    # outcome. Content-Length mismatches are treated as errors: the partial
    # file is discarded and `CacheResult::Error` is returned.
    private def download(key : String, upstream : String) : CacheResult
      is_immutable = immutable?(key)
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}
      # Conditional revalidation for index files we already have.
      if !is_immutable && (mtime = @cache.modification_time?(key))
        headers["If-Modified-Since"] = HTTP.format_time(mtime)
      end

      result = CacheResult::Error
      fetch(upstream, headers) do |response|
        case response.status_code
        when 200
          expected = response.headers["Content-Length"]?.try(&.to_i64?)
          @cache.store(key, response.body_io)
          stored = @cache.size(key)
          if expected && stored != expected
            @cache.invalidate(key)
            Log.error { "incomplete download #{upstream}: expected #{expected} B, got #{stored} B" }
            result = CacheResult::Error
            # body not fully consumed — the connection stream is dirty, discard it
            false
          else
            Log.debug { "fetched #{upstream} -> #{format_bytes(stored)}" }
            result = CacheResult::Miss
            # body fully consumed by store — connection is clean
            true
          end
        when 304
          # refresh the freshness window
          @cache.touch(key) if !is_immutable
          Log.debug { "revalidated #{upstream}" }
          result = CacheResult::Revalidated
          # no body — connection is clean
          true
        else
          response.body
          Log.warn { "upstream #{response.status_code} for #{upstream}" }
          # non-2xx body drain is unreliable — discard the connection
          false
        end
      end
      result
    rescue ex
      Log.warn { "fetch failed: #{upstream} — #{ex.message}" }
      CacheResult::Error
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
    private def fetch(url : String, headers : HTTP::Headers, &) : Nil
      current = url
      redirects = 0

      loop do
        follow = nil
        uri = URI.parse(current)

        checked_get(uri, headers) do |response|
          if response.status_code.in?(301, 302, 303, 307, 308) &&
             (location = response.headers["Location"]?)
            follow = URI.parse(current).resolve(location).to_s
            # drain redirect body to allow connection reuse
            response.body
            true
          else
            # propagates the Bool returned by download's block
            yield response
          end
        end

        break unless follow
        raise "too many redirects starting from #{url}" if redirects >= @max_redirects
        redirects += 1
        Log.debug { "redirect #{current} -> #{follow}" }
        current = follow
      end
    end

    # Borrows a connection from the pool, runs the block, returns the connection.
    # On IO::Error BEFORE the body starts (stale pooled connection), retries once
    # with a fresh connection. IO errors during body transfer (disk full, etc.)
    # are not retried as they do not originate from the upstream connection.
    private def checked_get(uri : URI, headers : HTTP::Headers, &) : Nil
      retried = false
      client = @pool.checkout(uri)
      configure_client(client)
      loop do
        body_started = false
        reuse = false
        begin
          client.get(uri.path, headers: headers) do |response|
            body_started = true
            # block returns true if the connection is safe to reuse
            reuse = yield response
          end
          reuse ? @pool.checkin(uri, client) : @pool.discard(client)
          break
        rescue ex : IO::Error
          @pool.discard(client)
          raise ex if retried || body_started
          retried = true
          client = HTTP::Client.new(uri)
          configure_client(client)
        rescue ex
          @pool.discard(client)
          raise ex
        end
      end
    end

    # Applies connect and read timeouts to *client*.
    private def configure_client(client : HTTP::Client) : Nil
      client.connect_timeout = @connect_timeout
      client.read_timeout = @read_timeout
    end

    # Streams *key* from the cache to *res*. Handles `Range` requests (206)
    # and `HEAD` (headers only). Returns the number of bytes written.
    private def serve(key : String, res : HTTP::Server::Response, head_only : Bool, range : String? = nil) : Int64
      file = @cache.open(key)
      begin
        total = file.size
        res.content_type = "application/octet-stream"

        if range && (bounds = parse_range(range, total))
          first, last = bounds
          length = last - first + 1
          res.status = HTTP::Status::PARTIAL_CONTENT
          res.headers["Content-Range"] = "bytes #{first}-#{last}/#{total}"
          res.content_length = length
          return length if head_only
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
          return total if head_only
          buffered_copy(file, res)
          total
        end
      ensure
        file.close
      end
    end

    # Parses a `Range: bytes=first-last` header against *total* file size.
    # Returns {first, last} clamped to valid bounds, or nil for invalid ranges.
    private def parse_range(header : String, total : Int64) : {Int64, Int64}?
      return nil unless header.starts_with?("bytes=")
      spec = header[6..]
      dash = spec.index('-') || return nil
      start_str = spec[0, dash]
      end_str = spec[dash + 1..]

      if start_str.empty?
        # Suffix range: bytes=-N (last N bytes)
        suffix = end_str.to_i64? || return nil
        first = [total - suffix, 0_i64].max
        {first, total - 1}
      else
        first = start_str.to_i64? || return nil
        last = end_str.empty? ? total - 1 : (end_str.to_i64? || return nil)
        last = [last, total - 1].min
        return nil if first > last || first >= total
        {first, last}
      end
    end

    # Opens a transparent TCP tunnel for CONNECT requests.
    #
    # The proxy connects to the target host:port, sends HTTP 200, then relays
    # bytes in both directions until either side closes. HTTPS traffic is not
    # inspected or cached — TLS is negotiated end-to-end between APT and the
    # upstream mirror.
    private def tunnel(req : HTTP::Request, res : HTTP::Server::Response, started_at : Time::Span) : Nil
      host, _, port_str = req.resource.rpartition(":")
      port = port_str.to_i? || 443

      upstream = TCPSocket.new(host, port, connect_timeout: @connect_timeout)
      upstream.read_timeout = @read_timeout

      # upgrade() writes HTTP headers (status 200) and yields the raw client socket.
      # The socket has sync=false (HTTP::Server default) so we must flush after
      # each write — otherwise TLS handshake bytes sit in the buffer and the
      # handshake times out ("Error in the push function").
      res.headers.delete("Content-Type")
      res.upgrade do |client|
        done = Channel(Nil).new
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
      Log.info { "200 TUNNEL CONNECT #{req.resource}" }
    rescue ex
      res.status = HTTP::Status::BAD_GATEWAY
      res.puts "tunnel failed: #{ex.message}"
      log_access(req.method, req.resource, res.status_code, started_at, CacheResult::Error, client: req.remote_address)
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
    private def log_access(method : String, key : String, status : Int32, started_at : Time::Span, cache_result : CacheResult, bytes : Int64? = nil, client : Socket::Address? = nil) : Nil
      case cache_result
      in .hit?         then @stat_hits.add(1)
      in .miss?        then @stat_misses.add(1)
      in .revalidated? then @stat_revalidations.add(1)
      in .error?       then @stat_errors.add(1)
      end
      @stat_bytes.add(bytes) if bytes
      return if @quiet && (cache_result.hit? || cache_result.revalidated?)
      elapsed_ms = (Time.monotonic - started_at).total_milliseconds
      elapsed = elapsed_ms >= 1000 ? "#{(elapsed_ms / 1000).round(1)}s" : "#{elapsed_ms.round}ms"
      tag = case cache_result
            in .hit?         then "HIT  "
            in .miss?        then "MISS "
            in .revalidated? then "REVAL"
            in .error?       then "WARN "
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
