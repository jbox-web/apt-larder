require "./spec_helper"
require "file_utils"

Spectator.describe AptLarder::Proxy do
  let(tmp_dir) { spec_tmp_dir("proxy") }
  let(cache) { AptLarder::Cache.new(tmp_dir) }
  let(sf) { AptLarder::SingleFlight.new }
  let(proxy) { AptLarder::Proxy.new(cache, sf, max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30) }

  after_each { FileUtils.rm_rf(tmp_dir) }

  private def make_ctx(method : String, url : String) : HTTP::Server::Context
    req = HTTP::Request.new(method, url)
    res = HTTP::Server::Response.new(IO::Memory.new)
    HTTP::Server::Context.new(req, res)
  end

  private def store(key : String, content : String) : Nil
    cache.store(key, IO::Memory.new(content.to_slice))
  end

  # Writes a file + bad SHA256 sidecar directly to disk, bypassing cache.store
  # so @verified is not populated — forces valid?() to actually read the sidecar.
  private def plant_corrupt(key : String, content : String) : Nil
    path = File.join(tmp_dir, key)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.write("#{path}.sha256", "deadbeef" * 8)
  end

  describe "error cases" do
    it "CONNECT to unreachable host returns 502" do
      sock = TCPServer.new("127.0.0.1", 0)
      closed_port = sock.local_address.port
      sock.close
      ctx = make_ctx("CONNECT", "127.0.0.1:#{closed_port}")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(502)
    end

    # Guards the refused-connect detection: a connected upstream must still
    # get a working tunnel.
    it "CONNECT to a reachable host answers 200 and relays bytes both ways" do
      echo = TCPServer.new("127.0.0.1", 0)
      spawn do
        if peer = echo.accept?
          if line = peer.gets
            peer.puts "echo:#{line}"
            peer.flush
          end
          peer.close
        end
      end

      server = HTTP::Server.new do |ctx|
        proxy.handle(ctx)
      rescue IO::Error | HTTP::Server::ClientError
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      client = TCPSocket.new("127.0.0.1", addr.port)
      client.read_timeout = 5.seconds
      client << "CONNECT 127.0.0.1:#{echo.local_address.port} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
      client.flush
      status_line = client.gets
      while (header = client.gets) && !header.empty?
      end
      client.puts "ping"
      client.flush
      reply = client.gets

      client.close
      server.close
      echo.close

      expect(status_line).to eq("HTTP/1.1 200 OK")
      expect(reply).to eq("echo:ping")
    end

    it "rejects non-GET/HEAD methods with 405" do
      ctx = make_ctx("POST", "/mirror/pkg.deb")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(405)
    end

    it "rejects path traversal with 400" do
      ctx = make_ctx("GET", "/evil/../../../etc/passwd")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
    end

    it "returns 400 for unmappable path" do
      ctx = make_ctx("GET", "/")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
    end
  end

  describe "liveness probe" do
    it "answers /_health with 200 without resolving anything" do
      ctx = make_ctx("GET", "/_health")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "answers a HEAD probe with 200" do
      ctx = make_ctx("HEAD", "/_health")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    # The probe fires every 30s under Docker's HEALTHCHECK. Booked as a request
    # it would invent ~2880 unmappable-URL errors a day in the proxy counters,
    # in /api/metrics and in the access log — which is what made the endpoint
    # necessary in the first place.
    it "does not book the probe into the counters" do
      proxy.handle(make_ctx("GET", "/_health"))
      expect(proxy.stats[:errors]).to eq(0)
      expect(proxy.stats[:hits]).to eq(0)
      expect(proxy.stats[:misses]).to eq(0)
    end

    it "still rejects a non-GET/HEAD probe path with 405" do
      ctx = make_ctx("POST", "/_health")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(405)
    end

    # Only the origin-form resource is the probe. A mirror that happens to
    # publish a /_health path must keep being proxied, not shadowed.
    it "does not shadow an upstream path named _health" do
      store("mirror.example.com/_health", "upstream-payload")
      ctx = make_ctx("GET", "/mirror.example.com/_health")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(proxy.stats[:hits]).to eq(1)
    end
  end

  describe "resolve — host-in-path mode" do
    it "serves a cached file via host-in-path URL" do
      store("mirror.example.com/debian/pool/main/pkg.deb", "data")
      ctx = make_ctx("GET", "/mirror.example.com/debian/pool/main/pkg.deb")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "returns 400 when only one path segment is present (no trailing path)" do
      ctx = make_ctx("GET", "/onlyhostnoslash")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
    end
  end

  describe "resolve — cache key format" do
    it "includes non-standard port in the cache key" do
      server = HTTP::Server.new do |ctx|
        ctx.response.content_type = "application/octet-stream"
        ctx.response.print("data")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      proxy.handle(make_ctx("GET", "http://127.0.0.1:#{addr.port}/debian/pkg.deb"))
      server.close

      expect(cache.exists?("127.0.0.1:#{addr.port}/debian/pkg.deb")).to be_true
    end

    it "omits default port 80 from the cache key" do
      # Pre-store with the no-port key; the request carries :80 explicitly.
      # If resolve strips the default port correctly, the cache is hit.
      store("example.com/debian/pkg.deb", "data")
      ctx = make_ctx("GET", "http://example.com:80/debian/pkg.deb")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end
  end

  describe "host remapping" do
    it "fetches from the remapped host but caches under the original key" do
      server = HTTP::Server.new do |ctx|
        ctx.response.print("remapped content")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      remapped_proxy = AptLarder::Proxy.new(
        cache, AptLarder::SingleFlight.new,
        max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30,
        remaps: {"original.mirror" => "127.0.0.1:#{addr.port}"}
      )

      remapped_proxy.handle(make_ctx("GET", "http://original.mirror/debian/pkg.deb"))
      server.close

      # Cache key uses original host, not the remapped one.
      expect(cache.exists?("original.mirror/debian/pkg.deb")).to be_true
    end

    it "leaves URLs unchanged when no remap matches" do
      store("mirror/pool/main/pkg.deb", "data")
      remapped_proxy = AptLarder::Proxy.new(
        cache, AptLarder::SingleFlight.new,
        max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30,
        remaps: {"other.host" => "127.0.0.1:9999"}
      )
      ctx = make_ctx("GET", "/mirror/pool/main/pkg.deb")
      remapped_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "prepends path from full-URL remap target" do
      received_path = ""
      server = HTTP::Server.new do |ctx|
        received_path = ctx.request.path
        ctx.response.print("ok")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      remapped_proxy = AptLarder::Proxy.new(
        cache, AptLarder::SingleFlight.new,
        max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30,
        remaps: {"docker" => "http://127.0.0.1:#{addr.port}/linux/debian"}
      )

      remapped_proxy.handle(make_ctx("GET", "/docker/dists/bullseye/InRelease"))
      server.close

      expect(received_path).to eq("/linux/debian/dists/bullseye/InRelease")
      expect(cache.exists?("docker/dists/bullseye/InRelease")).to be_true
    end

    it "parses remaps from YAML config" do
      config = AptLarder::Config.from_yaml(<<-YAML)
        remaps:
          deb.debian.org: my-mirror.lan
          security.debian.org: "http://mirror2.lan:8080"
        YAML
      expect(config.remaps["deb.debian.org"]).to eq("my-mirror.lan")
      expect(config.remaps["security.debian.org"]).to eq("http://mirror2.lan:8080")
    end
  end

  describe "immutable? heuristic" do
    # index_ttl=0 makes every non-immutable file appear stale immediately.
    # Immutable files must be served from cache regardless.
    let(zero_ttl_proxy) { AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30) }

    it "treats .deb as immutable (cache hit even with TTL=0)" do
      store("mirror/pool/main/pkg.deb", "data")
      ctx = make_ctx("GET", "/mirror/pool/main/pkg.deb")
      zero_ttl_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "treats .udeb as immutable" do
      store("mirror/pool/main/pkg.udeb", "data")
      ctx = make_ctx("GET", "/mirror/pool/main/pkg.udeb")
      zero_ttl_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "treats .ddeb as immutable" do
      store("mirror/pool/main/pkg.ddeb", "data")
      ctx = make_ctx("GET", "/mirror/pool/main/pkg.ddeb")
      zero_ttl_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "treats /by-hash/ path as immutable" do
      store("mirror/dists/stable/by-hash/SHA256/abc", "data")
      ctx = make_ctx("GET", "/mirror/dists/stable/by-hash/SHA256/abc")
      zero_ttl_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "treats Release as mutable (TTL=0 forces upstream fetch)" do
      sock = TCPServer.new("127.0.0.1", 0)
      port = sock.local_address.port
      sock.close

      store("127.0.0.1:#{port}/dists/stable/Release", "content")
      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/dists/stable/Release")
      zero_ttl_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(502)
    end
  end

  describe "stats" do
    it "increments hit counter on HIT" do
      store("mirror/pool/main/pkg.deb", "data")
      proxy.handle(make_ctx("GET", "/mirror/pool/main/pkg.deb"))
      expect(proxy.stats[:hits]).to eq(1)
    end

    it "increments miss counter on MISS" do
      server = HTTP::Server.new do |ctx|
        ctx.response.print("data")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield
      proxy.handle(make_ctx("GET", "http://127.0.0.1:#{addr.port}/debian/pkg.deb"))
      server.close
      expect(proxy.stats[:misses]).to eq(1)
    end

    it "increments revalidation counter on 304" do
      server = HTTP::Server.new do |ctx|
        ctx.response.status = HTTP::Status::NOT_MODIFIED
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      reval_proxy = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30)
      store("127.0.0.1:#{addr.port}/dists/stable/Release", "content")
      reval_proxy.handle(make_ctx("GET", "http://127.0.0.1:#{addr.port}/dists/stable/Release"))
      server.close

      expect(reval_proxy.stats[:revalidations]).to eq(1)
    end

    it "increments error counter on bad request" do
      proxy.handle(make_ctx("GET", "/"))
      expect(proxy.stats[:errors]).to eq(1)
    end

    it "accumulates bytes served" do
      store("mirror/pool/main/pkg.deb", "hello")
      proxy.handle(make_ctx("GET", "/mirror/pool/main/pkg.deb"))
      expect(proxy.stats[:bytes]).to eq(5)
    end
  end

  describe "stale in-memory cache (file deleted from disk)" do
    it "returns 502 and invalidates the entry" do
      store("mirror/pool/main/pkg.deb", "data")
      expect(cache.exists?("mirror/pool/main/pkg.deb")).to be_true

      FileUtils.rm_rf(tmp_dir)

      ctx = make_ctx("GET", "/mirror/pool/main/pkg.deb")
      proxy.handle(ctx)

      expect(ctx.response.status_code).to eq(502)
      expect(cache.exists?("mirror/pool/main/pkg.deb")).to be_false
    end
  end

  describe "upstream error passthrough" do
    it "passes 404 from upstream through to the client" do
      server = HTTP::Server.new do |ctx|
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.print("not found")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/dists/stable/Release")
      proxy.handle(ctx)
      server.close

      expect(ctx.response.status_code).to eq(404)
    end

    it "passes 503 from upstream through to the client" do
      server = HTTP::Server.new do |ctx|
        ctx.response.status = HTTP::Status::SERVICE_UNAVAILABLE
        ctx.response.print("unavailable")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/dists/stable/Release")
      proxy.handle(ctx)
      server.close

      expect(ctx.response.status_code).to eq(503)
    end

    it "returns 502 when upstream is unreachable (connection error)" do
      sock = TCPServer.new("127.0.0.1", 0)
      closed_port = sock.local_address.port
      sock.close

      ctx = make_ctx("GET", "http://127.0.0.1:#{closed_port}/dists/stable/Release")
      proxy.handle(ctx)

      expect(ctx.response.status_code).to eq(502)
    end
  end

  describe "query string forwarding (host-in-path mode)" do
    it "forwards the query string to the upstream request" do
      received = Channel(String).new(1)
      server = HTTP::Server.new do |ctx|
        received.send(ctx.request.resource)
        ctx.response.print("ok")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      # host-in-path form with a signed-URL style query string
      ctx = make_ctx("GET", "/127.0.0.1:#{addr.port}/dists/stable/Release?token=abc&exp=1")
      proxy.handle(ctx)
      target = received.receive
      server.close

      expect(ctx.response.status_code).to eq(200)
      expect(target).to eq("/dists/stable/Release?token=abc&exp=1")
    end
  end

  describe "HEAD on a MISS" do
    it "fetches from upstream and responds with headers only (no body)" do
      server = HTTP::Server.new do |ctx|
        ctx.response.content_type = "application/octet-stream"
        ctx.response.print("pkg")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("HEAD", "http://127.0.0.1:#{addr.port}/pool/main/pkg.deb")
      proxy.handle(ctx)
      server.close

      expect(ctx.response.status_code).to eq(200)
      expect(ctx.response.headers["Content-Length"]).to eq("3")
      expect(cache.exists?("127.0.0.1:#{addr.port}/pool/main/pkg.deb")).to be_true
    end
  end

  describe "Range requests (206)" do
    private def make_range_ctx(range : String) : HTTP::Server::Context
      req = HTTP::Request.new("GET", "/mirror/pool/main/pkg.deb",
        HTTP::Headers{"Range" => range})
      res = HTTP::Server::Response.new(IO::Memory.new)
      HTTP::Server::Context.new(req, res)
    end

    before_each { store("mirror/pool/main/pkg.deb", "0123456789") }

    it "returns 206 with the requested byte range" do
      ctx = make_range_ctx("bytes=2-5")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(206)
      expect(ctx.response.headers["Content-Range"]).to eq("bytes 2-5/10")
      expect(ctx.response.headers["Content-Length"]).to eq("4")
    end

    it "handles open-ended range bytes=N-" do
      ctx = make_range_ctx("bytes=7-")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(206)
      expect(ctx.response.headers["Content-Range"]).to eq("bytes 7-9/10")
    end

    it "handles suffix range bytes=-N" do
      ctx = make_range_ctx("bytes=-3")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(206)
      expect(ctx.response.headers["Content-Range"]).to eq("bytes 7-9/10")
    end

    it "falls back to 200 for an invalid range" do
      ctx = make_range_ctx("bytes=20-30")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "falls back to 200 for a zero-length suffix range bytes=-0" do
      ctx = make_range_ctx("bytes=-0")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end
  end

  describe "cache HIT" do
    it "serves an immutable file from cache with 200" do
      store("mirror/pool/main/pkg.deb", "package data")
      ctx = make_ctx("GET", "/mirror/pool/main/pkg.deb")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "HEAD returns 200 with Content-Length and no body" do
      store("mirror/pool/main/pkg.deb", "12345")
      ctx = make_ctx("HEAD", "/mirror/pool/main/pkg.deb")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(ctx.response.headers["Content-Length"]).to eq("5")
    end

    it "HEAD does not count any bytes as served (no body written)" do
      store("mirror/pool/main/pkg.deb", "12345")
      ctx = make_ctx("HEAD", "/mirror/pool/main/pkg.deb")
      proxy.handle(ctx)
      expect(proxy.stats[:bytes]).to eq(0)
    end

    # Integration test over a real TCP socket — exercises the sendfile(2) path
    # which is skipped when the response is backed by IO::Memory.
    it "serves a HIT correctly over a real TCP socket (exercises sendfile)" do
      store("mirror/pool/main/pkg.deb", "hello from cache")

      server = HTTP::Server.new do |ctx|
        proxy.handle(ctx)
      rescue IO::Error | HTTP::Server::ClientError
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      response = HTTP::Client.get(
        "http://127.0.0.1:#{addr.port}/mirror/pool/main/pkg.deb",
        headers: HTTP::Headers{"Connection" => "close"}
      )
      server.close

      expect(response.status_code).to eq(200)
      expect(response.body).to eq("hello from cache")
    end
  end

  describe "cache MISS (fake upstream)" do
    let(fake_upstream) do
      server = HTTP::Server.new do |ctx|
        ctx.response.content_type = "application/octet-stream"
        ctx.response.print("upstream content")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield
      {server, addr.port}
    end

    after_each { fake_upstream[0].close }

    it "fetches, caches and serves the file" do
      _, port = fake_upstream
      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/debian/pkg.deb")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(cache.exists?("127.0.0.1:#{port}/debian/pkg.deb")).to be_true
    end

    it "returns 502 when upstream is unreachable" do
      sock = TCPServer.new("127.0.0.1", 0)
      closed_port = sock.local_address.port
      sock.close

      ctx = make_ctx("GET", "http://127.0.0.1:#{closed_port}/debian/pkg.deb")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(502)
    end

    it "single-flight: 3 concurrent requests produce only one upstream fetch" do
      request_count = 0
      mutex = Mutex.new

      server = HTTP::Server.new do |ctx|
        mutex.synchronize { request_count += 1 }
        sleep 30.milliseconds
        ctx.response.print("body")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      port = addr.port
      spawn { server.listen }
      Fiber.yield

      done = Channel(Int32).new
      3.times do
        spawn do
          ctx = make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/pkg.deb")
          proxy.handle(ctx)
          done.send(ctx.response.status_code)
        end
      end

      statuses = 3.times.map { done.receive }.to_a
      server.close

      expect(request_count).to eq(1)
      expect(statuses).to all(eq(200))
    end
  end

  describe "revalidation (304)" do
    let(reval_proxy) { AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30) }

    it "sends the stored Last-Modified as If-Modified-Since and handles 304" do
      received_ims = nil
      server = HTTP::Server.new do |ctx|
        received_ims = ctx.request.headers["If-Modified-Since"]?
        ctx.response.status = HTTP::Status::NOT_MODIFIED
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      key = "127.0.0.1:#{addr.port}/dists/stable/Release"
      cache.store(key, IO::Memory.new("old content".to_slice), last_modified: "Wed, 01 Jan 2020 00:00:00 GMT")

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/dists/stable/Release")
      reval_proxy.handle(ctx)
      server.close

      # Echoed verbatim, not the local file mtime (which is "now").
      expect(received_ims).to eq("Wed, 01 Jan 2020 00:00:00 GMT")
      expect(ctx.response.status_code).to eq(200)
      expect(reval_proxy.stats[:revalidations]).to eq(1)
    end

    it "sends the stored ETag as If-None-Match" do
      received_inm = nil
      server = HTTP::Server.new do |ctx|
        received_inm = ctx.request.headers["If-None-Match"]?
        ctx.response.status = HTTP::Status::NOT_MODIFIED
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      key = "127.0.0.1:#{addr.port}/dists/stable/Release"
      cache.store(key, IO::Memory.new("old content".to_slice), etag: %("abc123"))

      reval_proxy.handle(make_ctx("GET", "http://127.0.0.1:#{addr.port}/dists/stable/Release"))
      server.close

      expect(received_inm).to eq(%("abc123"))
    end

    # RFC 9110 makes If-None-Match override If-Modified-Since. Behind a
    # round-robin mirror, a node still on the previous file has another ETag and
    # would answer 200 with that older file, rolling the cache back.
    it "sends only If-Modified-Since when both validators are stored" do
      received_inm = "unset"
      received_ims = nil
      server = HTTP::Server.new do |ctx|
        received_inm = ctx.request.headers["If-None-Match"]?
        received_ims = ctx.request.headers["If-Modified-Since"]?
        ctx.response.status = HTTP::Status::NOT_MODIFIED
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      key = "127.0.0.1:#{addr.port}/dists/stable/Release"
      cache.store(key, IO::Memory.new("old content".to_slice), last_modified: "Wed, 01 Jan 2020 00:00:00 GMT", etag: %("abc123"))

      reval_proxy.handle(make_ctx("GET", "http://127.0.0.1:#{addr.port}/dists/stable/Release"))
      server.close

      expect(received_ims).to eq("Wed, 01 Jan 2020 00:00:00 GMT")
      expect(received_inm).to be_nil
    end

    # A `.validators` sidecar can outlive its data file (crash inside
    # invalidate, manual rm). A conditional GET would then get a 304 for a file
    # we no longer have and answer 502.
    it "sends an unconditional GET when only an orphaned validators sidecar remains" do
      conditional = true
      server = HTTP::Server.new do |ctx|
        conditional = ctx.request.headers.has_key?("If-Modified-Since")
        if conditional
          ctx.response.status = HTTP::Status::NOT_MODIFIED
        else
          ctx.response.print("fresh content")
        end
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      key = "127.0.0.1:#{addr.port}/dists/stable/Release"
      path = File.join(tmp_dir, key)
      Dir.mkdir_p(File.dirname(path))
      File.write("#{path}.validators", "Last-Modified: Wed, 01 Jan 2020 00:00:00 GMT\n")

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/dists/stable/Release")
      reval_proxy.handle(ctx)
      server.close

      expect(conditional).to be_false
      expect(ctx.response.status_code).to eq(200)
      expect(File.read(path)).to eq("fresh content")
    end

    it "sends an unconditional GET for an index entry without stored validators" do
      conditional = true
      server = HTTP::Server.new do |ctx|
        conditional = ctx.request.headers.has_key?("If-Modified-Since") || ctx.request.headers.has_key?("If-None-Match")
        ctx.response.print("fresh content")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      store("127.0.0.1:#{addr.port}/dists/stable/Release", "legacy content")

      reval_proxy.handle(make_ctx("GET", "http://127.0.0.1:#{addr.port}/dists/stable/Release"))
      server.close

      expect(conditional).to be_false
    end

    # Regression: a 304 from a mirror that had not synced yet used to reset the
    # local mtime to "now", which was then sent as If-Modified-Since. The new
    # upstream file (Last-Modified older than "now") was then answered with 304
    # forever and APT kept receiving the expired Release file.
    it "fetches a new upstream version published after a 304 from a lagging mirror" do
      phase = :initial
      server = HTTP::Server.new do |ctx|
        case phase
        when :initial
          ctx.response.headers["Last-Modified"] = "Wed, 01 Jan 2020 00:00:00 GMT"
          ctx.response.print("version 1")
        when :lagging
          ctx.response.status = HTTP::Status::NOT_MODIFIED
        else
          # Real If-Modified-Since semantics against the new file.
          if (ims = ctx.request.headers["If-Modified-Since"]?) && HTTP.parse_time(ims).try { |time| time >= Time.utc(2020, 1, 2) }
            ctx.response.status = HTTP::Status::NOT_MODIFIED
          else
            ctx.response.headers["Last-Modified"] = "Thu, 02 Jan 2020 00:00:00 GMT"
            ctx.response.print("version 2")
          end
        end
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield
      url = "http://127.0.0.1:#{addr.port}/dists/stable/Release"

      reval_proxy.handle(make_ctx("GET", url))
      phase = :lagging
      reval_proxy.handle(make_ctx("GET", url))
      phase = :updated
      reval_proxy.handle(make_ctx("GET", url))
      server.close

      expect(File.read(File.join(tmp_dir, "127.0.0.1:#{addr.port}/dists/stable/Release"))).to eq("version 2")
    end

    it "does not send If-Modified-Since for an immutable file" do
      received_ims = false
      server = HTTP::Server.new do |ctx|
        received_ims = ctx.request.headers.has_key?("If-Modified-Since")
        ctx.response.content_type = "application/octet-stream"
        ctx.response.print("data")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/pool/main/pkg.deb")
      proxy.handle(ctx)
      server.close

      expect(received_ims).to be_false
    end

    it "does not keep validators for an immutable file (never revalidated)" do
      server = HTTP::Server.new do |ctx|
        ctx.response.headers["Last-Modified"] = "Wed, 01 Jan 2020 00:00:00 GMT"
        ctx.response.print("data")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      proxy.handle(make_ctx("GET", "http://127.0.0.1:#{addr.port}/pool/main/pkg.deb"))
      server.close

      expect(File.exists?(File.join(tmp_dir, "127.0.0.1:#{addr.port}/pool/main/pkg.deb.validators"))).to be_false
    end
  end

  # `.sha256` and `.validators` sidecars share the cache key namespace. A key
  # with one of those suffixes must neither expose nor overwrite the sidecar of
  # another entry: it is relayed from upstream and never touches the cache.
  describe "sidecar-suffixed keys" do
    let(upstream_hits) { [0] }
    let(fake_upstream) do
      hits = upstream_hits
      server = HTTP::Server.new do |ctx|
        hits[0] += 1
        ctx.response.content_type = "text/plain"
        ctx.response.print("upstream body")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield
      {server, addr.port}
    end

    after_each { fake_upstream[0].close }

    it "does not serve the cached validators sidecar of an entry" do
      _, port = fake_upstream
      key = "127.0.0.1:#{port}/dists/stable/Release"
      cache.store(key, IO::Memory.new("release".to_slice), last_modified: "Wed, 01 Jan 2020 00:00:00 GMT")

      ctx = make_ctx("GET", "http://#{key}.validators")
      proxy.handle(ctx)

      expect(upstream_hits[0]).to eq(1)
      expect(ctx.response.status_code).to eq(200)
    end

    it "does not overwrite the sidecar of an entry with the upstream body" do
      _, port = fake_upstream
      key = "127.0.0.1:#{port}/dists/stable/Release"
      cache.store(key, IO::Memory.new("release".to_slice), last_modified: "Wed, 01 Jan 2020 00:00:00 GMT")
      reval_proxy = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30)

      reval_proxy.handle(make_ctx("GET", "http://#{key}.validators"))
      reval_proxy.handle(make_ctx("GET", "http://#{key}.sha256"))

      expect(File.read(File.join(tmp_dir, "#{key}.validators"))).to eq("Last-Modified: Wed, 01 Jan 2020 00:00:00 GMT\n")
      expect(File.read(File.join(tmp_dir, "#{key}.sha256"))).to eq(Digest::SHA256.hexdigest("release"))
    end

    # On a case-insensitive filesystem (APFS, Docker Desktop bind mounts)
    # Release.SHA256 is the very file Release.sha256.
    it "treats sidecar suffixes case-insensitively" do
      _, port = fake_upstream
      key = "127.0.0.1:#{port}/dists/stable/Release"
      cache.store(key, IO::Memory.new("release".to_slice), last_modified: "Wed, 01 Jan 2020 00:00:00 GMT")
      reval_proxy = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30)

      reval_proxy.handle(make_ctx("GET", "http://#{key}.SHA256"))
      reval_proxy.handle(make_ctx("GET", "http://#{key}.Validators"))

      expect(upstream_hits[0]).to eq(2)
      expect(Dir.children(File.dirname(File.join(tmp_dir, key))).sort!).to eq(["Release", "Release.sha256", "Release.validators"])
      expect(File.read(File.join(tmp_dir, "#{key}.sha256"))).to eq(Digest::SHA256.hexdigest("release"))
    end

    # IO::Sized stops at EOF without raising, so a short body must be caught by
    # comparing the relayed byte count with Content-Length, as download does.
    it "counts a relayed body shorter than Content-Length as an error" do
      raw = TCPServer.new("127.0.0.1", 0)
      spawn do
        if peer = raw.accept?
          while (line = peer.gets) && !line.empty?
          end
          peer << "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n" << "x" * 400
          peer.flush
          peer.close
        end
      end

      proxy.handle(make_ctx("GET", "http://127.0.0.1:#{raw.local_address.port}/images/disk.iso.sha256"))
      raw.close

      expect(proxy.stats[:errors]).to eq(1)
      expect(proxy.stats[:misses]).to eq(0)
    end

    # The client was promised Content-Length bytes. Unless the connection is
    # closed, HTTP::Server keeps it alive and both sides wait on each other.
    it "closes the client connection after a truncated relayed body" do
      raw = TCPServer.new("127.0.0.1", 0)
      spawn do
        if peer = raw.accept?
          while (line = peer.gets) && !line.empty?
          end
          peer << "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n" << "x" * 400
          peer.flush
          peer.close
        end
      end

      server = HTTP::Server.new do |ctx|
        proxy.handle(ctx)
      rescue IO::Error | HTTP::Server::ClientError
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      client = TCPSocket.new("127.0.0.1", addr.port)
      client.read_timeout = 2.seconds
      client << "GET http://127.0.0.1:#{raw.local_address.port}/images/disk.iso.sha256 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
      client.flush
      while (header = client.gets) && !header.empty?
      end
      body = Bytes.new(1000)
      received = 0
      closed = false
      begin
        loop do
          n = client.read(body[received..])
          if n == 0
            closed = true
            break
          end
          received += n
        end
      rescue IO::TimeoutError
      end

      client.close
      server.close
      raw.close

      expect(received).to eq(400)
      expect(closed).to be_true
    end

    it "relays a published .sha256 file without caching it" do
      _, port = fake_upstream

      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/images/disk.iso.sha256")
      proxy.handle(ctx)

      expect(ctx.response.status_code).to eq(200)
      expect(upstream_hits[0]).to eq(1)
      # "upstream body" streamed to the client
      expect(proxy.stats[:bytes]).to eq(13)
      expect(File.exists?(File.join(tmp_dir, "127.0.0.1:#{port}/images/disk.iso.sha256"))).to be_false
    end

    it "passes an upstream error status through" do
      server = HTTP::Server.new do |ctx|
        ctx.response.status = HTTP::Status::NOT_FOUND
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/images/disk.iso.sha256")
      proxy.handle(ctx)
      server.close

      expect(ctx.response.status_code).to eq(404)
    end
  end

  describe "redirect following" do
    it "follows a 301 redirect to the final resource" do
      port = 0
      server = HTTP::Server.new do |ctx|
        if ctx.request.path == "/redirect"
          ctx.response.headers["Location"] = "http://127.0.0.1:#{port}/final/pkg.deb"
          ctx.response.status = HTTP::Status::MOVED_PERMANENTLY
        else
          ctx.response.content_type = "application/octet-stream"
          ctx.response.print("final content")
        end
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      port = addr.port
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/redirect")
      proxy.handle(ctx)
      server.close

      # Content is cached under the original request key, not the redirect target.
      expect(ctx.response.status_code).to eq(200)
      expect(cache.exists?("127.0.0.1:#{port}/redirect")).to be_true
    end

    # Real mirrors (nginx http->https) answer 301 with an HTML body. If that
    # body is left in the socket, the connection is checked back into the pool
    # still holding it, and the next request on that connection reads the HTML
    # as a status line — "Invalid HTTP response", raised before any round-trip.
    it "drains the 301 body so the pooled connection stays usable" do
      port = 0
      server = HTTP::Server.new do |ctx|
        if ctx.request.path == "/redirect"
          ctx.response.headers["Location"] = "http://127.0.0.1:#{port}/final/pkg.deb"
          ctx.response.status = HTTP::Status::MOVED_PERMANENTLY
          ctx.response.print("<html>\n<head><title>301 Moved Permanently</title></head>\n</html>\n")
        else
          ctx.response.content_type = "application/octet-stream"
          ctx.response.print("final content")
        end
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      port = addr.port
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/redirect")
      proxy.handle(ctx)
      server.close

      expect(ctx.response.status_code).to eq(200)
      expect(cache.exists?("127.0.0.1:#{port}/redirect")).to be_true
    end

    it "returns 502 when max_redirects is exceeded" do
      port = 0
      server = HTTP::Server.new do |ctx|
        ctx.response.headers["Location"] = "http://127.0.0.1:#{port}/loop"
        ctx.response.status = HTTP::Status::MOVED_PERMANENTLY
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      port = addr.port
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/loop")
      proxy.handle(ctx)
      server.close

      expect(ctx.response.status_code).to eq(502)
    end
  end

  describe "incomplete download (Content-Length mismatch)" do
    # Crystal's HTTP::Server keeps connections alive (keep-alive by default), so
    # a server that declares Content-Length but sends less would cause the proxy
    # to wait for the full read_timeout. Raw TCPServer lets us close the
    # connection immediately after sending a partial response, which is what a
    # real misbehaving upstream actually does.

    private def raw_upstream(response : String, &) : Int32
      tcp = TCPServer.new("127.0.0.1", 0)
      port = tcp.local_address.port
      spawn do
        if sock = tcp.accept?
          while (line = sock.gets) && line.strip != ""; end
          sock << response
          sock.close
          tcp.close
        end
      end
      Fiber.yield
      yield port
      port
    end

    it "returns 502 and does not cache when upstream sends fewer bytes than Content-Length" do
      raw_upstream("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 1000\r\nConnection: close\r\n\r\ntiny") do |port|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/pkg.deb")
        proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(502)
        expect(cache.exists?("127.0.0.1:#{port}/pool/main/pkg.deb")).to be_false
      end
    end

    it "does not cache an empty body when Content-Length is non-zero" do
      raw_upstream("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 191000\r\nConnection: close\r\n\r\n") do |port|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/pkg.deb")
        proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(502)
        expect(cache.exists?("127.0.0.1:#{port}/pool/main/pkg.deb")).to be_false
      end
    end

    it "caches normally when Content-Length matches the body" do
      server = HTTP::Server.new do |ctx|
        ctx.response.content_type = "application/octet-stream"
        ctx.response.print("x" * 512)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/pool/main/pkg.deb")
      proxy.handle(ctx)
      server.close

      expect(ctx.response.status_code).to eq(200)
      expect(cache.exists?("127.0.0.1:#{addr.port}/pool/main/pkg.deb")).to be_true
    end
  end

  describe "upstream non-2xx responses" do
    {% for status in [403, 404, 500] %}
    it "passes upstream {{status.id}} through to the client and does not cache" do
      server = HTTP::Server.new do |ctx|
        ctx.response.status_code = {{status}}
        ctx.response.print("error")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/debian/pkg.deb")
      proxy.handle(ctx)
      server.close

      expect(ctx.response.status_code).to eq({{status}})
      expect(cache.exists?("127.0.0.1:#{addr.port}/debian/pkg.deb")).to be_false
    end
    {% end %}
  end

  describe "stale pooled connection retry" do
    # Tests the checked_get retry path: when the pool hands out a dead
    # connection the proxy must retry exactly once with a fresh connection.
    #
    # A raw TCPServer lets us control each connection individually:
    # conn 1 is served normally (proxy pools it), then we close the server
    # side to make it stale, then conn 2 (the retry) is served normally.
    it "retries once and succeeds when the pooled connection is dead" do
      conn1_done = Channel(TCPSocket).new(1)
      conn_num = Atomic(Int32).new(0)

      tcp = TCPServer.new("127.0.0.1", 0)
      port = tcp.local_address.port

      spawn do
        while sock = tcp.accept?
          n = conn_num.add(1) + 1
          csock = sock
          spawn do
            begin
              while (line = csock.gets) && line.chomp.size > 0; end
              if n == 1
                # Keep-alive so the proxy checks this connection back into the pool.
                csock << "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\ndata"
                conn1_done.send(csock)
              else
                # Retry connection: serve normally and close.
                csock << "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 5\r\nConnection: close\r\n\r\nretry"
                csock.close
              end
            rescue
              csock.close rescue nil
            end
          end
        end
      end
      Fiber.yield

      # Request 1 — connection goes back into the pool after body is consumed.
      proxy.handle(make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/a.deb"))

      # Close the server side to make the pooled connection stale.
      conn1_done.receive.close
      Fiber.yield

      # Request 2 — proxy checks out the stale connection, gets IO::Error
      # before body_started, retries with a fresh connection (conn 2), succeeds.
      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/b.deb")
      proxy.handle(ctx)
      tcp.close

      expect(ctx.response.status_code).to eq(200)
    end

    # A pooled connection can be poisoned rather than dead: leftover bytes make
    # the next response unparseable, which the stdlib reports as a bare
    # Exception ("Invalid HTTP response"), not an IO::Error. The retry must
    # cover that too — the failure happens before any body byte is yielded, so
    # the request is just as replayable as on a dead socket.
    it "retries once when the pooled connection yields an unparseable response" do
      conn_num = Atomic(Int32).new(0)

      tcp = TCPServer.new("127.0.0.1", 0)
      port = tcp.local_address.port

      spawn do
        while sock = tcp.accept?
          n = conn_num.add(1) + 1
          csock = sock
          spawn do
            begin
              if n == 1
                # Request 1: valid keep-alive response, so the proxy pools this
                # connection. Request 2 on it: a line that cannot be a status
                # line, exactly what leftover HTML looks like.
                while (line = csock.gets) && line.chomp.size > 0; end
                csock << "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\ndata"
                while (line = csock.gets) && line.chomp.size > 0; end
                csock << "<html>\r\n"
                csock.close
              else
                while (line = csock.gets) && line.chomp.size > 0; end
                csock << "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 5\r\nConnection: close\r\n\r\nretry"
                csock.close
              end
            rescue
              csock.close rescue nil
            end
          end
        end
      end
      Fiber.yield

      # Request 1 — connection goes back into the pool.
      proxy.handle(make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/a.deb"))

      # Request 2 — checks out the poisoned connection, fails to parse, retries.
      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/b.deb")
      proxy.handle(ctx)
      tcp.close

      expect(ctx.response.status_code).to eq(200)
      expect(cache.exists?("127.0.0.1:#{port}/pool/main/b.deb")).to be_true
    end
  end

  describe "corrupt immutable file" do
    it "invalidates and re-downloads a .deb with a bad SHA256 sidecar" do
      server = HTTP::Server.new do |ctx|
        ctx.response.content_type = "application/octet-stream"
        ctx.response.print("fresh content")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      key = "127.0.0.1:#{addr.port}/pool/main/pkg.deb"
      plant_corrupt(key, "corrupted")

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/pool/main/pkg.deb")
      proxy.handle(ctx)
      server.close

      expect(ctx.response.status_code).to eq(200)
      expect(cache.valid?(key)).to be_true
    end
  end
end
