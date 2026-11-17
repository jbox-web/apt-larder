require "./spec_helper"
require "file_utils"

Spectator.describe AptLarder::Healthcheck do
  let(io) { IO::Memory.new }

  private def config(port : Int32, host : String = "127.0.0.1") : AptLarder::Config
    AptLarder::Config.from_yaml(<<-YAML)
      server_host: "#{host}"
      server_port: #{port}
      YAML
  end

  # Mirrors the upstream harness in `proxy_spec.cr`: bind on port 0 so the
  # kernel picks a free one, serve from a spawned fiber, close when done.
  # Every resource the stub is asked for is appended to *requested*, so an
  # example can assert what the probe actually put on the wire.
  private def with_proxy_server(status : Int32, requested : Array(String) = [] of String, &)
    server = HTTP::Server.new do |ctx|
      requested << ctx.request.resource
      ctx.response.status_code = status
      ctx.response.content_type = "text/plain"
      ctx.response.print("ok")
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield addr.port
    ensure
      server.close
    end
  end

  # Serves a real `AptLarder::Proxy` — the handler the released binary runs —
  # on a free loopback port.
  private def with_real_proxy(&)
    cache_dir = spec_tmp_dir("healthcheck")
    proxy = AptLarder::Proxy.new(AptLarder::Cache.new(cache_dir), AptLarder::SingleFlight.new,
      max_redirects: 5, index_ttl: 5, connect_timeout: 1, read_timeout: 1)
    server = HTTP::Server.new { |ctx| proxy.handle(ctx) }
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield addr.port, proxy
    ensure
      server.close
      FileUtils.rm_rf(cache_dir)
    end
  end

  # Binds then immediately releases a port, so the number is known to be free.
  private def unused_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    port
  end

  describe ".run" do
    it "returns 0 when the proxy answers 2xx" do
      code = with_proxy_server(200) do |port|
        described_class.run(config(port), io)
      end
      expect(code).to eq(0)
      expect(io.to_s).to contain("healthy")
      expect(io.to_s).to contain("/_health")
    end

    # The stub answers 200 on every path: only the recorded resource tells
    # which one the probe asked for.
    it "requests exactly /_health, once" do
      requested = [] of String
      with_proxy_server(200, requested) do |port|
        described_class.run(config(port), io)
      end
      expect(requested).to eq(["/_health"])
    end

    # End to end against the handler the binary serves: the path the probe
    # asks for has to be the one the proxy answers, without resolving it to a
    # mirror and without booking it.
    it "returns 0 against a real proxy handler" do
      errors = -1_i64
      code = with_real_proxy do |port, proxy|
        result = described_class.run(config(port), io)
        errors = proxy.stats[:errors]
        result
      end
      expect(code).to eq(0)
      expect(errors).to eq(0)
    end

    it "returns 1 when the proxy answers non-2xx" do
      code = with_proxy_server(503) do |port|
        described_class.run(config(port), io)
      end
      expect(code).to eq(1)
      expect(io.to_s).to contain("503")
    end

    it "returns 1 when nothing is listening" do
      code = described_class.run(config(unused_port), io)
      expect(code).to eq(1)
      expect(io.to_s).to contain("unhealthy")
      # One readable line, no exception class and no backtrace.
      expect(io.to_s.lines.size).to eq(1)
    end

    # The regression that made this probe move off the admin API: the released
    # image bakes a HEALTHCHECK that carries no --config, so every deployment
    # whose config lives elsewhere ran on defaults. Defaults keep the admin
    # server off, so the container went red while the proxy served fine.
    it "reports healthy on a pure default config, with no config file at all" do
      code = with_proxy_server(200) do |port|
        # Only the port is overridden; everything else is the shipped default,
        # admin.enabled included.
        cfg = AptLarder::Config.from_yaml("server_port: #{port}\n")
        expect(cfg.admin.enabled?).to be_false
        described_class.run(cfg, io)
      end
      expect(code).to eq(0)
    end

    # 0.0.0.0 is what the container actually binds, and it is not a routable
    # destination on every platform — the probe has to dial loopback instead.
    it "dials loopback when the server binds a wildcard address" do
      code = with_proxy_server(200) do |port|
        described_class.run(config(port, host: "0.0.0.0"), io)
      end
      expect(code).to eq(0)
      expect(io.to_s).to contain("127.0.0.1")
    end
  end
end
