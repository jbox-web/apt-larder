require "./spec_helper"
require "file_utils"

Spectator.describe AptLarder::Proxy do
  let(tmp_dir) { "/tmp/apt-larder-proxy-#{Random::Secure.hex(4)}" }
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
    it "sends If-Modified-Since for a stale index file and handles 304" do
      received_ims = false
      server = HTTP::Server.new do |ctx|
        received_ims = ctx.request.headers.has_key?("If-Modified-Since")
        ctx.response.status = HTTP::Status::NOT_MODIFIED
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      reval_proxy = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30)
      store("127.0.0.1:#{addr.port}/dists/stable/Release", "old content")

      ctx = make_ctx("GET", "http://127.0.0.1:#{addr.port}/dists/stable/Release")
      reval_proxy.handle(ctx)
      server.close

      expect(received_ims).to be_true
      expect(ctx.response.status_code).to eq(200)
      expect(reval_proxy.stats[:revalidations]).to eq(1)
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
