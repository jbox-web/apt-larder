module AptLarder
  # Per-host pool of idle `HTTP::Client` connections.
  #
  # Reusing connections avoids the TCP and TLS handshake overhead on every
  # upstream request. The pool is keyed by `scheme://host:port` so that
  # connections to different ports on the same host are kept separate.
  #
  # At most `IDLE_PER_HOST` connections are retained per host. Connections
  # returned when the pool is full are closed immediately.
  #
  # All methods are safe to call from concurrent fibers.
  class ConnectionPool
    # Maximum number of idle connections kept per upstream host.
    # 4 covers the typical APT concurrency (a handful of parallel downloads)
    # without risking file-descriptor exhaustion.
    IDLE_PER_HOST = 4

    # Pooled connections idle longer than this are assumed dead — the upstream
    # may have closed its keep-alive — and are discarded on checkout instead of
    # risking a wasted round-trip on a stale socket. Kept below the typical
    # server keep-alive timeout (60s).
    IDLE_TTL = 50.seconds

    # A pooled connection paired with the monotonic instant it went idle.
    private record Entry, client : HTTP::Client, idle_since : Time::Span

    def initialize
      @idle = {} of String => Array(Entry)
      @mutex = Mutex.new
    end

    # Returns *client* to the pool for *uri* so it can be reused.
    #
    # If the pool for this host already holds `IDLE_PER_HOST` connections,
    # *client* is closed immediately rather than queued. *now* is injectable
    # for tests; production callers use the default monotonic clock.
    def checkin(uri : URI, client : HTTP::Client, now : Time::Span = Time.monotonic) : Nil
      key = host_key(uri)
      # Close outside the lock: client.close performs a socket close(2) syscall,
      # which should not serialise other fibers' checkout/checkin.
      evicted = @mutex.synchronize do
        pool = (@idle[key] ||= [] of Entry)
        if pool.size < IDLE_PER_HOST
          pool.push(Entry.new(client, now))
          nil
        else
          client
        end
      end
      evicted.try(&.close)
    end

    # Returns a pooled connection for *uri*, or creates a new one if none is
    # available. Connections idle beyond `IDLE_TTL` are closed and skipped.
    # The host bucket is dropped once empty so the table cannot grow unbounded.
    def checkout(uri : URI, now : Time::Span = Time.monotonic) : HTTP::Client
      key = host_key(uri)
      # Collect expired connections and close them after releasing the lock —
      # a socket close(2) must not serialise other fibers on the pool.
      stale = [] of HTTP::Client
      reused = @mutex.synchronize do
        pool = @idle[key]?
        next nil unless pool
        client = nil
        while entry = pool.pop?
          if now - entry.idle_since <= IDLE_TTL
            client = entry.client
            break
          end
          stale << entry.client
        end
        @idle.delete(key) if pool.empty?
        client
      end
      stale.each { |client| client.close rescue nil }
      reused || HTTP::Client.new(uri)
    end

    # Closes *client* and discards it. Silently ignores errors (e.g. already
    # closed). Use this when the connection is known to be dirty or broken.
    def discard(client : HTTP::Client) : Nil
      client.close rescue nil
    end

    private def host_key(uri : URI) : String
      # Port is included so that two servers on the same host at different
      # ports (e.g. http :80 and https :443) get separate pools.
      port = uri.port || URI.default_port(uri.scheme || "http") || 80
      "#{uri.scheme}://#{uri.host}:#{port}"
    end
  end
end
