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

    # Builds all shared objects (cache, single-flight, proxy) from *config*.
    # No I/O happens here; `start` does the actual binding.
    def initialize(@config : Config)
      @cache = Cache.new(@config.cache_dir)
      @sf = SingleFlight.new
      @proxy = Proxy.new(
        @cache, @sf,
        max_redirects: @config.max_redirects,
        index_ttl: @config.index_ttl,
        connect_timeout: @config.connect_timeout,
        read_timeout: @config.read_timeout,
        quiet: @config.quiet?,
        remaps: @config.remaps
      )
      @http_server = nil.as(HTTP::Server?)
      @in_flight = Atomic(Int32).new(0)
    end

    # Starts the HTTP server and blocks until `stop` is called.
    # Waits for all in-flight requests to finish before returning.
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
        spawn { admin.start }
      end

      start_eviction_loop if @config.evict_after_days > 0 || @config.max_cache_size_gb > 0
      start_stats_loop

      addr = server.bind_tcp(@config.server_host, @config.server_port)
      Log.info { "apt-larder listening on http://#{addr}" }

      SystemD.status("listening on http://#{addr}")
      SystemD.start_watchdog
      SystemD.ready

      server.listen

      # Graceful shutdown: drain in-flight requests before returning.
      SystemD.stopping
      while @in_flight.get > 0
        sleep 50.milliseconds
      end
    ensure
      @http_server = nil
    end

    # Stops accepting new connections. `start` will return once in-flight
    # requests finish.
    def stop : Nil
      @http_server.try(&.close)
    end

    # Spawns a background fiber that runs `Cache#evict` once per hour.
    # Called only when at least one eviction strategy is configured.
    private def start_eviction_loop : Nil
      max_age = @config.evict_after_days > 0 ? @config.evict_after_days.days : nil
      limit = @config.max_cache_size_gb > 0 ? (@config.max_cache_size_gb * 1_073_741_824).to_i64 : nil
      spawn do
        loop do
          sleep 1.hour
          deleted, freed = @cache.evict(max_age: max_age, limit_bytes: limit)
          if deleted > 0
            freed_mb = (freed / 1_048_576.0).round(1)
            Log.info { "eviction: removed #{deleted} files, freed #{freed_mb} MB" }
          end
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
          served_mb = (s[:bytes] / 1_048_576.0).round(1)
          msg = "#{s[:hits]} hits (#{hit_pct}%), #{s[:misses]} misses, #{served_mb} MB served"
          Log.info { "stats: #{msg}, #{s[:revalidations]} revalidated, #{s[:errors]} errors" }
          SystemD.status(msg)
        end
      end
    end
  end
end
