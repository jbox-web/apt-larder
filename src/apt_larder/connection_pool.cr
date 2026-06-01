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

    def initialize
      @idle = {} of String => Array(HTTP::Client)
      @mutex = Mutex.new
    end

    # Returns *client* to the pool for *uri* so it can be reused.
    #
    # If the pool for this host already holds `IDLE_PER_HOST` connections,
    # *client* is closed immediately rather than queued.
    def checkin(uri : URI, client : HTTP::Client) : Nil
      key = host_key(uri)
      @mutex.synchronize do
        pool = (@idle[key] ||= [] of HTTP::Client)
        pool.size < IDLE_PER_HOST ? pool.push(client) : client.close
      end
    end

    # Returns a pooled connection for *uri*, or creates a new one if none is
    # available.
    def checkout(uri : URI) : HTTP::Client
      key = host_key(uri)
      @mutex.synchronize { @idle[key]?.try(&.pop?) } || HTTP::Client.new(uri)
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
