module AptLarder
  # The probe the binary runs against itself.
  #
  # It exists because the released image is distroless
  # (`gcr.io/distroless/static-debian12`): no shell, no curl, no wget. A
  # `HEALTHCHECK CMD curl ...` cannot work there, so the only thing able to
  # speak HTTP inside that container is apt-larder itself.
  #
  # Deliberately a subcommand rather than a flag on the running server: Docker
  # runs the check by exec'ing a second process into the container, and what it
  # wants back is an exit code.
  #
  # It probes the **proxy**, not the admin server. The admin server is optional
  # and off by default, and the baked HEALTHCHECK carries no `--config`, so a
  # probe pointed at the admin API reported unhealthy on every deployment whose
  # config lives outside the working directory — while the proxy was serving
  # packages perfectly. What the container exists to do is the only thing worth
  # gating its health on.
  module Healthcheck
    # Short on purpose. A probe that hangs is a probe that reports nothing, and
    # `Proxy::HEALTH_PATH` is answered before any resolution, cache lookup or
    # upstream call — it never waits on anything.
    TIMEOUT = 2.seconds

    # Addresses that mean "every interface" when bound, and nothing routable
    # when dialled. The container binds `0.0.0.0` and the probe runs inside it,
    # so loopback is the address that actually reaches the listener.
    WILDCARD_HOSTS = {"0.0.0.0", "::", "[::]", ""}

    # 0 when the proxy answers 2xx on `Proxy::HEALTH_PATH`, 1 otherwise —
    # including when nothing is listening, which is itself the answer.
    def self.run(config : Config, io : IO = STDOUT) : Int32
      host = probe_host(config.server_host)
      port = config.server_port

      begin
        response = probe(host, port)
      rescue ex : IO::Error
        # Connection refused, reset, or timed out: one readable line, no
        # exception class and no backtrace — the output lands in the
        # `docker inspect` health log, which is read by a human at 3am.
        io.puts "unhealthy: cannot reach the proxy at #{host}:#{port} — #{ex.message}"
        return 1
      end

      unless response.success?
        io.puts "unhealthy: proxy answered #{response.status_code} on #{host}:#{port}#{Proxy::HEALTH_PATH}"
        return 1
      end

      io.puts "healthy: proxy answered #{Proxy::HEALTH_PATH} on #{host}:#{port}"
      0
    end

    # A fresh client rather than `HTTP::Client.get`: the class method exposes
    # no timeout setter, and a request that never returns is the one failure
    # mode this probe must not have.
    private def self.probe(host : String, port : Int32) : HTTP::Client::Response
      client = HTTP::Client.new(host, port)
      client.connect_timeout = TIMEOUT
      client.read_timeout = TIMEOUT
      begin
        client.get(Proxy::HEALTH_PATH)
      ensure
        client.close
      end
    end

    # The address to dial for a server bound to *server_host*.
    private def self.probe_host(server_host : String) : String
      return "127.0.0.1" if WILDCARD_HOSTS.includes?(server_host)
      server_host
    end
  end
end
