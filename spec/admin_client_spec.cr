require "./spec_helper"

Spectator.describe AptLarder::Admin::Client do
  # What the stub server saw, so the assertions bear on the request the client
  # actually put on the wire rather than on the reply it got back.
  alias Captured = NamedTuple(method: String, resource: String, body: String, authorization: String?)

  # Serves *status* / *body* for every request and records the last one.
  # Mirrors the upstream harness in `proxy_spec.cr`.
  private def with_stub(status : Int32 = 200, body : String = %({"ok":true}), &)
    captured = [] of Captured
    server = HTTP::Server.new do |ctx|
      captured << {
        method:        ctx.request.method,
        resource:      ctx.request.resource,
        body:          ctx.request.body.try(&.gets_to_end) || "",
        authorization: ctx.request.headers["Authorization"]?,
      }
      ctx.response.status_code = status
      ctx.response.content_type = "application/json"
      ctx.response.print(body)
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield config_for(addr.port), captured
    ensure
      server.close
    end
  end

  private def config_for(port : Int32, api_token : String = "") : AptLarder::AdminConfig
    AptLarder::AdminConfig.from_yaml(<<-YAML)
      enabled: true
      host: "127.0.0.1"
      port: #{port}
      api_token: "#{api_token}"
      YAML
  end

  private def unused_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    port
  end

  describe "#health" do
    it "issues GET /api/health and parses the body" do
      with_stub(body: %({"status":"ok","version":"1.2.3"})) do |config, captured|
        json = described_class.new(config).health
        expect(json["status"].as_s).to eq("ok")
        expect(captured.last[:method]).to eq("GET")
        expect(captured.last[:resource]).to eq("/api/health")
      end
    end
  end

  describe "#stats" do
    it "issues GET /api/stats" do
      with_stub(body: %({"hits":7})) do |config, captured|
        expect(described_class.new(config).stats["hits"].as_i).to eq(7)
        expect(captured.last[:resource]).to eq("/api/stats")
      end
    end
  end

  describe "#cache_list" do
    it "carries pagination and prefix in the query string" do
      with_stub(body: %({"total":0,"entries":[]})) do |config, captured|
        described_class.new(config).cache_list("deb.debian.org", 2, 25)
        expect(captured.last[:method]).to eq("GET")
        expect(captured.last[:resource]).to eq("/api/cache?prefix=deb.debian.org&page=2&per_page=25")
      end
    end

    it "omits an empty prefix" do
      with_stub(body: %({"total":0,"entries":[]})) do |config, captured|
        described_class.new(config).cache_list
        expect(captured.last[:resource]).to eq("/api/cache?page=1&per_page=50")
      end
    end
  end

  describe "#cache_flush" do
    it "issues DELETE /api/cache" do
      with_stub(body: %({"deleted":3})) do |config, captured|
        expect(described_class.new(config).cache_flush["deleted"].as_i).to eq(3)
        expect(captured.last[:method]).to eq("DELETE")
        expect(captured.last[:resource]).to eq("/api/cache")
      end
    end
  end

  describe "#cache_invalidate" do
    it "URL-encodes the key and accepts 204 without a body to parse" do
      with_stub(status: 204, body: "") do |config, captured|
        described_class.new(config).cache_invalidate("mirror/pool/main/pkg.deb")
        expect(captured.last[:method]).to eq("DELETE")
        expect(captured.last[:resource]).to eq("/api/cache/mirror%2Fpool%2Fmain%2Fpkg.deb")
      end
    end

    it "raises on 404 with the status and body in the message" do
      with_stub(status: 404, body: %({"error":"not found"})) do |config, _|
        expect { described_class.new(config).cache_invalidate("absent.deb") }
          .to raise_error(AptLarder::Admin::Error, /404.*not found/)
      end
    end
  end

  describe "#evict" do
    it "POSTs the max_age_days override as a JSON body" do
      with_stub(body: %({"deleted":1,"freed_bytes":42})) do |config, captured|
        described_class.new(config).evict(7)
        expect(captured.last[:method]).to eq("POST")
        expect(captured.last[:resource]).to eq("/api/evict")
        expect(captured.last[:body]).to eq(%({"max_age_days":7}))
      end
    end

    it "POSTs an empty body when no override is given" do
      with_stub(body: %({"deleted":0,"freed_bytes":0})) do |config, captured|
        described_class.new(config).evict
        expect(captured.last[:body]).to be_empty
      end
    end
  end

  describe "authentication" do
    it "sends a Bearer header when api_token is set" do
      with_stub do |config, captured|
        described_class.new(config_for(config.port, api_token: "s3cret")).health
        expect(captured.last[:authorization]).to eq("Bearer s3cret")
      end
    end

    it "sends no Authorization header when api_token is empty" do
      with_stub do |config, captured|
        described_class.new(config).health
        expect(captured.last[:authorization]).to be_nil
      end
    end
  end

  describe "failures" do
    it "wraps a non-2xx response in Admin::Error" do
      with_stub(status: 503, body: %({"error":"nope"})) do |config, _|
        expect { described_class.new(config).health }
          .to raise_error(AptLarder::Admin::Error, /503/)
      end
    end

    it "wraps an unreachable server in Admin::Error naming host and port" do
      port = unused_port
      expect { described_class.new(config_for(port)).health }
        .to raise_error(AptLarder::Admin::Error, /cannot reach admin server at 127\.0\.0\.1:#{port}/)
    end

    it "wraps an unparseable body in Admin::Error" do
      with_stub(body: "not json at all") do |config, _|
        expect { described_class.new(config).health }
          .to raise_error(AptLarder::Admin::Error, /invalid JSON response/)
      end
    end
  end

  describe "timeout" do
    # The bound the healthcheck subcommand depends on. Connecting to a routable
    # but silent address is what makes a connect actually hang; 203.0.113.0/24
    # is the TEST-NET-3 block, reserved by RFC 5737 and never routed.
    it "gives up on connect once the timeout elapses" do
      config = AptLarder::AdminConfig.from_yaml(%(enabled: true\nhost: "203.0.113.1"\nport: 8080\n))
      elapsed = Time.measure do
        expect { described_class.new(config, timeout: 200.milliseconds).health }
          .to raise_error(AptLarder::Admin::Error)
      end
      expect(elapsed).to be < 3.seconds
    end
  end
end
