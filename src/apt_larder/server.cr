module AptLarder
  # Owns the full lifecycle of one server run: cache, proxy, HTTP listener,
  # background loops (eviction, stats) and graceful shutdown.
  #
  # Usage:
  #   server = Server.new(config)
  #   Signal::TERM.trap { server.stop }
  #   server.start   # blocks until stop is called and all requests drain
  class Server
    Log = ::Log.for("apt-larder.server")

    # Maximum time to wait for in-flight requests to drain on shutdown before
    # returning anyway. Keep below systemd's default TimeoutStopSec (90s).
    SHUTDOWN_DRAIN_TIMEOUT = 30.seconds

    # How often idle upstream connections past their keep-alive are closed.
    POOL_SWEEP_INTERVAL = 1.minute

    # How often the eviction pass runs once the server is up.
    EVICTION_INTERVAL = 1.hour

    # Address the proxy listens on, `nil` while it is not started.
    getter address : Socket::IPAddress?

    # Address the admin server listens on, `nil` when it is disabled or not
    # started.
    getter admin_address : Socket::IPAddress?

    # Builds all shared objects (cache, single-flight, proxy) from *config*.
    # No network I/O happens here; `start` does the actual binding. The cache
    # is not scanned either: on a large cache that takes long enough to matter
    # for systemd's start timeout, so `start` does it once it is listening.
    def initialize(@config : Config)
      @cache = Cache.new(@config.cache_dir, scan: false)
      @sf = SingleFlight.new
      @proxy = Proxy.new(
        @cache, @sf,
        max_redirects: @config.max_redirects,
        index_ttl: @config.index_ttl,
        connect_timeout: @config.connect_timeout,
        read_timeout: @config.read_timeout,
        quiet: @config.quiet?,
        remaps: @config.remaps,
        allow_local_targets: @config.allow_local_targets?,
        connect_ports: @config.connect_ports
      )
      @http_server = nil.as(HTTP::Server?)
      @admin = nil.as(Admin::Server?)
      @in_flight = Atomic(Int32).new(0)
    end

    # Starts the HTTP server and blocks until `stop` is called.
    # Waits for all in-flight requests to finish before returning.
    #
    # Both listeners are bound before the service is announced as ready: a
    # bind failure on either (`Socket::BindError`) is raised to the caller.
    def start : Nil
      server = HTTP::Server.new do |ctx|
        @in_flight.add(1)
        begin
          @proxy.handle(ctx)
        rescue HTTP::Server::ClientError
          # client disconnected mid-transfer — not an error
        rescue ex : IO::Error
          # only swallow socket-level errors (broken pipe, connection reset);
          # re-raise anything else (e.g. disk errors) so it isn't silently hidden
          raise ex unless ex.os_error.in?(Errno::EPIPE, Errno::ECONNRESET)
        ensure
          @in_flight.sub(1)
        end
      end
      @http_server = server

      if @config.admin.enabled?
        admin = Admin::Server.new(@config.admin, @cache, @proxy, @config.evict_after_days)
        @admin = admin
        @admin_address = admin.bind
      end

      addr = server.bind_tcp(@config.server_host, @config.server_port)
      @address = addr
      Log.info { "apt-larder listening on http://#{addr}" }

      @admin.try { |listener| spawn { listener.listen } }
      start_maintenance_loop
      start_pool_sweep_loop
      start_stats_loop

      SystemD.status("listening on http://#{addr}")
      SystemD.start_watchdog
      SystemD.ready

      server.listen

      # Graceful shutdown: drain in-flight requests before returning, but cap
      # the wait so a single stuck request (slow client, huge .deb) cannot block
      # shutdown forever. systemd's TimeoutStopSec would otherwise SIGKILL us.
      SystemD.stopping
      deadline = Time.instant + SHUTDOWN_DRAIN_TIMEOUT
      while @in_flight.get > 0
        if Time.instant >= deadline
          Log.warn { "shutdown drain timed out with #{@in_flight.get} request(s) still in flight" }
          break
        end
        sleep 50.milliseconds
      end
    ensure
      @admin.try(&.close)
      @http_server = nil
      @admin = nil
      @address = nil
      @admin_address = nil
    end

    # Stops accepting new connections. `start` will return once in-flight
    # requests finish.
    def stop : Nil
      @admin.try(&.close)
      @http_server.try { |server| server.close unless server.closed? }
    end

    # Spawns the background fiber that looks after the cache: one disk scan to
    # seed the gauges, then — when at least one eviction strategy is
    # configured — an eviction pass right away and every `EVICTION_INTERVAL`.
    #
    # The first pass does not wait an hour: a process restarted more often
    # than that (a CI job container on a persistent volume) would otherwise
    # never evict anything. A pass that raises is logged and the loop goes on:
    # an eviction that stops silently is a disk that fills up.
    private def start_maintenance_loop : Nil
      max_age = @config.evict_after_days > 0 ? @config.evict_after_days.days : nil
      limit = @config.max_cache_size_gb > 0 ? (@config.max_cache_size_gb * 1_073_741_824).to_i64 : nil
      spawn do
        guarded("cache scan") { @cache.rescan }
        next unless max_age || limit
        loop do
          guarded("eviction") do
            deleted, freed = @cache.evict(max_age: max_age, limit_bytes: limit)
            Log.info { "eviction: removed #{deleted} files, freed #{AptLarder.format_bytes(freed)}" } if deleted > 0
          end
          sleep EVICTION_INTERVAL
        end
      end
    end

    # Spawns a background fiber that closes the upstream connections kept
    # idle past their keep-alive, for hosts that are not contacted again.
    private def start_pool_sweep_loop : Nil
      spawn do
        loop do
          sleep POOL_SWEEP_INTERVAL
          guarded("connection sweep") { @proxy.sweep_idle_connections }
        end
      end
    end

    # Spawns a background fiber that logs cumulative stats and updates
    # the systemd STATUS= once per hour.
    private def start_stats_loop : Nil
      spawn do
        loop do
          sleep 1.hour
          s = @proxy.stats
          total = s[:hits] + s[:misses]
          hit_pct = total > 0 ? (s[:hits] * 100.0 / total).round(1) : 0.0
          msg = "#{s[:hits]} hits (#{hit_pct}%), #{s[:misses]} misses, #{AptLarder.format_bytes(s[:bytes])} served"
          Log.info { "stats: #{msg}, #{s[:revalidations]} revalidated, #{s[:errors]} errors, #{s[:tunnels]} tunnels" }
          SystemD.status(msg)
        end
      end
    end

    # Runs a background *task*, logging instead of letting an exception end
    # the fiber it runs in.
    private def guarded(task : String, &) : Nil
      yield
    rescue ex
      Log.error(exception: ex) { "#{task} failed" }
    end
  end
end
