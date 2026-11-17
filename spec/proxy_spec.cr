require "./spec_helper"
require "file_utils"
require "log/spec"

Spectator.describe AptLarder::Proxy do
  let(tmp_dir) { spec_tmp_dir("proxy") }
  let(cache) { AptLarder::Cache.new(tmp_dir) }
  let(sf) { AptLarder::SingleFlight.new }
  let(proxy) { AptLarder::Proxy.new(cache, sf, max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30, allow_local_targets: true) }

  after_each { FileUtils.rm_rf(tmp_dir) }

  private def make_ctx(method : String, url : String) : HTTP::Server::Context
    req = HTTP::Request.new(method, url)
    res = HTTP::Server::Response.new(IO::Memory.new)
    HTTP::Server::Context.new(req, res)
  end

  private def store(key : String, content : String) : Nil
    cache.store(key, IO::Memory.new(content.to_slice))
  end

  # Body the handler wrote to the in-memory response of *ctx*.
  private def response_body(ctx : HTTP::Server::Context) : String
    ctx.response.flush
    raw = ctx.response.@io.as(IO::Memory).to_s
    raw.split("\r\n\r\n", 2)[1]? || ""
  end

  # Starts a local HTTP server driven by *handler*, yields its port, and
  # closes it afterwards.
  private def with_upstream(handler : HTTP::Server::Context ->, &)
    server = HTTP::Server.new(&handler)
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield addr.port
    ensure
      server.close
    end
  end

  # A port nothing listens on.
  private def closed_port : Int32
    sock = TCPServer.new("127.0.0.1", 0)
    port = sock.local_address.port
    sock.close
    port
  end

  # Writes a file + bad SHA256 sidecar directly to disk, bypassing cache.store
  # so @verified is not populated — forces valid?() to actually read the sidecar.
  private def plant_corrupt(key : String, content : String) : Nil
    path = File.join(tmp_dir, key)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.write("#{path}.sha256", "deadbeef" * 8)
  end

  # A proxy allowed to tunnel to a local test server listening on *port*.
  private def tunnel_proxy(port : Int32) : AptLarder::Proxy
    AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 5,
      connect_timeout: 10, read_timeout: 30, allow_local_targets: true, connect_ports: [port])
  end

  # The policy a default configuration gets: local targets refused, CONNECT
  # restricted to port 443.
  private def strict_proxy(remaps : Hash(String, String) = {} of String => String,
                           connect_ports : Array(Int32) = [443]) : AptLarder::Proxy
    AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 5,
      connect_timeout: 10, read_timeout: 30, remaps: remaps, connect_ports: connect_ports)
  end

  # Starts a local HTTP server that counts its requests, yields its port and
  # the counter, and closes it afterwards.
  private def with_local_server(body : String = "secret", &)
    hits = [] of String
    server = HTTP::Server.new do |ctx|
      hits << ctx.request.resource
      ctx.response.print(body)
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield addr.port, hits
    ensure
      server.close
    end
  end

  # Messages logged by the proxy while the block runs.
  private def captured_messages(&) : Array(String)
    messages = [] of String
    Log.capture("apt-larder.proxy") do |logs|
      yield
      messages = logs.@entries.map(&.message)
    end
    messages
  end

  describe "target policy (default configuration)" do
    it "refuses an absolute-form request for a loopback address with 403" do
      with_local_server do |port, hits|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/api/stats")
        strict_proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(403)
        expect(hits).to be_empty
        expect(cache.exists?("127.0.0.1:#{port}/api/stats")).to be_false
      end
    end

    it "refuses a host-in-path request for a loopback address with 403" do
      with_local_server do |port, hits|
        ctx = make_ctx("GET", "/127.0.0.1:#{port}/api/stats")
        strict_proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(403)
        expect(hits).to be_empty
      end
    end

    it "refuses a name that resolves to loopback with 403" do
      with_local_server do |port, hits|
        ctx = make_ctx("GET", "http://localhost:#{port}/api/stats")
        strict_proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(403)
        expect(hits).to be_empty
      end
    end

    it "refuses a link-local address (instance metadata) with 403" do
      ctx = make_ctx("GET", "http://169.254.169.254/latest/meta-data/")
      strict_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(403)
    end

    it "refuses a relayed sidecar-named key on a loopback address with 403" do
      with_local_server do |port, hits|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/Release.sha256")
        strict_proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(403)
        expect(hits).to be_empty
      end
    end

    it "books a refused target as an error" do
      target = strict_proxy
      target.handle(make_ctx("GET", "http://127.0.0.1:1/x"))
      expect(target.stats[:errors]).to eq(1)
      expect(target.stats[:misses]).to eq(0)
    end

    # A remap target comes from the configuration, not from the client: a
    # mirror running on the proxy's own host must stay reachable.
    it "still fetches from a loopback address named by a remap" do
      with_local_server("mirror content") do |port, hits|
        target = strict_proxy(remaps: {"local.mirror" => "127.0.0.1:#{port}"})
        ctx = make_ctx("GET", "http://local.mirror/debian/pkg.deb")
        target.handle(ctx)
        expect(ctx.response.status_code).to eq(200)
        expect(hits).to eq(["/debian/pkg.deb"])
      end
    end

    # Only the remap target itself is trusted: where it redirects to is as
    # untrusted as any client-supplied URL.
    it "refuses a redirect from a remapped mirror to a loopback address" do
      with_local_server do |secret_port, secret_hits|
        redirector = HTTP::Server.new do |ctx|
          ctx.response.headers["Location"] = "http://127.0.0.1:#{secret_port}/secret"
          ctx.response.status = HTTP::Status::FOUND
        end
        redirector_addr = redirector.bind_tcp("127.0.0.1", 0)
        spawn { redirector.listen }
        Fiber.yield

        target = strict_proxy(remaps: {"local.mirror" => "127.0.0.1:#{redirector_addr.port}"})
        ctx = make_ctx("GET", "http://local.mirror/debian/pkg.deb")
        target.handle(ctx)
        redirector.close

        expect(ctx.response.status_code).to eq(403)
        expect(secret_hits).to be_empty
        expect(cache.exists?("local.mirror/debian/pkg.deb")).to be_false
      end
    end

    it "refuses CONNECT to a port other than 443 with 403, without connecting" do
      accepted = 0
      listener = TCPServer.new("127.0.0.1", 0)
      spawn do
        while peer = listener.accept?
          accepted += 1
          peer.close
        end
      end
      ctx = make_ctx("CONNECT", "127.0.0.1:#{listener.local_address.port}")
      target = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 5,
        connect_timeout: 10, read_timeout: 30, allow_local_targets: true)
      target.handle(ctx)
      Fiber.yield
      listener.close
      expect(ctx.response.status_code).to eq(403)
      expect(accepted).to eq(0)
      expect(target.stats[:tunnels]).to eq(0)
    end

    it "refuses CONNECT to a loopback address on an allowed port with 403, without connecting" do
      accepted = 0
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.local_address.port
      spawn do
        while peer = listener.accept?
          accepted += 1
          peer.close
        end
      end
      ctx = make_ctx("CONNECT", "127.0.0.1:#{port}")
      strict_proxy(connect_ports: [port]).handle(ctx)
      Fiber.yield
      listener.close
      expect(ctx.response.status_code).to eq(403)
      expect(accepted).to eq(0)
    end

    it "answers 400 to a CONNECT whose port is not a number" do
      ctx = make_ctx("CONNECT", "deb.debian.org:https")
      strict_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
    end
  end

  describe "error cases" do
    it "CONNECT to unreachable host returns 502" do
      sock = TCPServer.new("127.0.0.1", 0)
      closed_port = sock.local_address.port
      sock.close
      ctx = make_ctx("CONNECT", "127.0.0.1:#{closed_port}")
      tunnel_proxy(closed_port).handle(ctx)
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

      echo_proxy = tunnel_proxy(echo.local_address.port)
      server = HTTP::Server.new do |ctx|
        echo_proxy.handle(ctx)
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
      expect(echo_proxy.stats[:tunnels]).to eq(1)
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

    # Same rule in proxy mode: `GET http://mirror/_health` names a file on a
    # mirror. Its path is /_health but its resource is not, and it is the
    # resource that designates the probe.
    it "proxies an absolute-form request whose path is /_health instead of answering it" do
      with_local_server("upstream health page") do |port, hits|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/_health")
        proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(200)
        expect(response_body(ctx)).to eq("upstream health page")
        expect(hits).to eq(["/_health"])
      end
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

    # The remap table is not empty, so the lookup really runs: a host it does
    # not name must be fetched where the client asked, and the remap target
    # must not see the request.
    it "sends a MISS to the requested host, resource unchanged, when no remap matches" do
      with_local_server("requested mirror") do |port, hits|
        with_local_server("remap target") do |decoy_port, decoy_hits|
          remapped_proxy = AptLarder::Proxy.new(
            cache, AptLarder::SingleFlight.new,
            max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30,
            remaps: {"other.host" => "127.0.0.1:#{decoy_port}"}, allow_local_targets: true
          )
          ctx = make_ctx("GET", "http://127.0.0.1:#{port}/debian/pkg.deb")
          remapped_proxy.handle(ctx)

          expect(ctx.response.status_code).to eq(200)
          expect(response_body(ctx)).to eq("requested mirror")
          expect(hits).to eq(["/debian/pkg.deb"])
          expect(decoy_hits).to be_empty
        end
      end
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
    let(zero_ttl_proxy) { AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30, allow_local_targets: true) }

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
      fetched = [] of String
      handler = ->(ctx : HTTP::Server::Context) do
        fetched << ctx.request.path
        ctx.response.print("new content")
      end
      with_upstream(handler) do |port|
        store("127.0.0.1:#{port}/dists/stable/Release", "content")
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/dists/stable/Release")
        zero_ttl_proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(200)
        expect(fetched).to eq(["/dists/stable/Release"])
        expect(response_body(ctx)).to eq("new content")
      end
    end
  end

  describe "access tracking for eviction" do
    it "refreshes the mtime of an immutable entry on a HIT" do
      store("mirror/pool/main/pkg.deb", "data")
      path = File.join(tmp_dir, "mirror/pool/main/pkg.deb")
      past = Time.utc - 10.days
      File.utime(past, past, path)
      ctx = make_ctx("GET", "/mirror/pool/main/pkg.deb")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(File.info(path).modification_time).to be > Time.utc - 1.minute
    end

    # The mtime of an index file is its freshness clock: a HIT must not
    # extend the TTL window.
    it "leaves the mtime of an index entry alone on a HIT" do
      store("mirror/dists/stable/Release", "data")
      path = File.join(tmp_dir, "mirror/dists/stable/Release")
      past = Time.utc - 2.minutes
      File.utime(past, past, path)
      reopened = AptLarder::Proxy.new(AptLarder::Cache.new(tmp_dir), AptLarder::SingleFlight.new,
        max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30)
      ctx = make_ctx("GET", "/mirror/dists/stable/Release")
      reopened.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(File.info(path).modification_time).to be < Time.utc - 1.minute
    end
  end

  describe "paths that are directories upstream" do
    let(mirror) do
      ->(ctx : HTTP::Server::Context) do
        case ctx.request.path
        when "/debian/pool/main/c/curl"            then ctx.response.print("<html>listing</html>")
        when "/debian/pool/main/c/curl/"           then ctx.response.print("<html>listing/</html>")
        when "/debian/pool/main/c/curl/curl_1.deb" then ctx.response.print("DEB")
        else                                            ctx.response.status = HTTP::Status::NOT_FOUND
        end
      end
    end

    it "still serves a package after its directory's index page was requested" do
      with_upstream(mirror) do |port|
        listing = make_ctx("GET", "/127.0.0.1:#{port}/debian/pool/main/c/curl")
        proxy.handle(listing)
        expect(listing.response.status_code).to eq(200)

        package = make_ctx("GET", "/127.0.0.1:#{port}/debian/pool/main/c/curl/curl_1.deb")
        proxy.handle(package)
        expect(package.response.status_code).to eq(200)
        expect(response_body(package)).to eq("DEB")
      end
    end

    it "relays the index page of a directory that already holds packages, without caching it" do
      with_upstream(mirror) do |port|
        proxy.handle(make_ctx("GET", "/127.0.0.1:#{port}/debian/pool/main/c/curl/curl_1.deb"))

        listing = make_ctx("GET", "/127.0.0.1:#{port}/debian/pool/main/c/curl")
        proxy.handle(listing)
        expect(listing.response.status_code).to eq(200)
        expect(response_body(listing)).to eq("<html>listing</html>")
        expect(cache.exists?("127.0.0.1:#{port}/debian/pool/main/c/curl")).to be_false
        expect(cache.exists?("127.0.0.1:#{port}/debian/pool/main/c/curl/curl_1.deb")).to be_true
      end
    end

    it "relays a path ending with a slash without caching it" do
      with_upstream(mirror) do |port|
        listing = make_ctx("GET", "/127.0.0.1:#{port}/debian/pool/main/c/curl/")
        proxy.handle(listing)
        expect(listing.response.status_code).to eq(200)
        expect(response_body(listing)).to eq("<html>listing/</html>")
        expect(cache.entry_count).to eq(0)
      end
    end
  end

  describe "keys shaped like a temporary download file" do
    it "relays them without caching" do
      handler = ->(ctx : HTTP::Server::Context) { ctx.response.print("payload") }
      with_upstream(handler) do |port|
        key = "127.0.0.1:#{port}/pool/pkg.deb.0123456789abcdef.tmp"
        ctx = make_ctx("GET", "/#{key}")
        proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(200)
        expect(response_body(ctx)).to eq("payload")
        expect(File.exists?(File.join(tmp_dir, key))).to be_false
      end
    end
  end

  describe "stale index when upstream fails" do
    let(zero_ttl_proxy) { AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30, allow_local_targets: true) }

    it "serves the cached copy when upstream is unreachable" do
      port = closed_port
      store("127.0.0.1:#{port}/dists/stable/Release", "cached release")
      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/dists/stable/Release")
      zero_ttl_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(response_body(ctx)).to eq("cached release")
      expect(zero_ttl_proxy.stats[:hits]).to eq(1)
      expect(zero_ttl_proxy.stats[:errors]).to eq(0)
    end

    it "serves the cached copy when upstream answers 503" do
      handler = ->(ctx : HTTP::Server::Context) { ctx.response.status = HTTP::Status::SERVICE_UNAVAILABLE }
      with_upstream(handler) do |port|
        store("127.0.0.1:#{port}/dists/stable/Release", "cached release")
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/dists/stable/Release")
        zero_ttl_proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(200)
        expect(response_body(ctx)).to eq("cached release")
      end
    end

    # A 404 is an answer, not an outage: the file is gone upstream.
    it "passes an upstream 404 through even with a cached copy" do
      handler = ->(ctx : HTTP::Server::Context) { ctx.response.status = HTTP::Status::NOT_FOUND }
      with_upstream(handler) do |port|
        store("127.0.0.1:#{port}/dists/stable/Release", "cached release")
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/dists/stable/Release")
        zero_ttl_proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(404)
      end
    end

    it "still fails when there is no cached copy" do
      ctx = make_ctx("GET", "http://127.0.0.1:#{closed_port}/dists/stable/Release")
      zero_ttl_proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(502)
    end
  end

  describe "upstream statuses that are neither a file nor an error" do
    {% for status in [203, 206, 300] %}
    it "answers 502 to an upstream {{status.id}} instead of relaying it" do
      handler = ->(ctx : HTTP::Server::Context) do
        ctx.response.status_code = {{status}}
        ctx.response.print("part")
      end
      with_upstream(handler) do |port|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/debian/pkg.deb")
        proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(502)
        expect(cache.exists?("127.0.0.1:#{port}/debian/pkg.deb")).to be_false
      end
    end
    {% end %}
  end

  describe "connection failures" do
    # Retrying exists for pooled connections that went stale. A connection
    # opened for this very request has nothing to recover from.
    #
    # The upstream reads the request and then resets the connection, which is
    # the one failure that reaches the proxy as it is: `HTTP::Client` retries
    # by itself, on a new connection, when the send fails or when the
    # response is a clean end of stream — and a plain `close` racing the
    # request produces either of those depending on timing.
    it "does not retry a request that failed on a fresh connection" do
      accepted = 0
      listener = TCPServer.new("127.0.0.1", 0)
      spawn do
        while peer = listener.accept?
          accepted += 1
          while (line = peer.gets) && !line.empty?; end
          # Linger 0 turns the close into a reset instead of an orderly end.
          peer.linger = 0
          peer.close
        end
      end
      ctx = make_ctx("GET", "http://127.0.0.1:#{listener.local_address.port}/debian/pkg.deb")
      proxy.handle(ctx)
      Fiber.yield
      listener.close
      expect(ctx.response.status_code).to eq(502)
      expect(accepted).to eq(1)
    end

    # An upstream that completes the TCP handshake and then stays silent is
    # only bounded by read_timeout. The request runs in its own fiber so that
    # a proxy without that bound fails this example instead of hanging the
    # suite.
    it "answers 502 once read_timeout elapses on an upstream that accepts and never answers" do
      listener = TCPServer.new("127.0.0.1", 0)
      held = [] of TCPSocket
      spawn do
        while peer = listener.accept?
          held << peer
        end
      end
      impatient = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 5,
        connect_timeout: 10, read_timeout: 1, allow_local_targets: true)
      ctx = make_ctx("GET", "http://127.0.0.1:#{listener.local_address.port}/debian/pkg.deb")

      finished = Channel(Time::Span).new(1)
      started = Time.instant
      spawn do
        impatient.handle(ctx)
        finished.send(started.elapsed)
      end

      begin
        select
        when elapsed = finished.receive
          expect(ctx.response.status_code).to eq(502)
          expect(elapsed).to be < 3.seconds
        when timeout(3.seconds)
          fail "the proxy was still waiting on upstream after 3 seconds"
        end
      ensure
        listener.close
        held.each(&.close)
      end
    end
  end

  describe "logging" do
    it "keeps the query string of an upstream URL out of the log" do
      handler = ->(ctx : HTTP::Server::Context) { ctx.response.status = HTTP::Status::INTERNAL_SERVER_ERROR }
      with_upstream(handler) do |port|
        Log.capture("apt-larder.proxy") do |logs|
          proxy.handle(make_ctx("GET", "/127.0.0.1:#{port}/debian/pkg.deb?token=s3cr3t"))
          messages = logs.@entries.map(&.message)
          expect(messages).not_to be_empty
          expect(messages.join("\n")).not_to contain("s3cr3t")
          expect(messages.join("\n")).to contain("/debian/pkg.deb")
        end
      end
    end

    # The access line is "<status> <tag> <method> <key>", the tag padded to
    # five characters so the columns line up.
    it "tags a request served from the cache with HIT" do
      store("mirror/pool/main/pkg.deb", "data")
      messages = captured_messages { proxy.handle(make_ctx("GET", "/mirror/pool/main/pkg.deb")) }
      expect(messages.join("\n")).to contain("200 HIT   GET mirror/pool/main/pkg.deb")
    end

    it "tags a request fetched from upstream with MISS" do
      with_local_server do |port, _|
        messages = captured_messages { proxy.handle(make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/pkg.deb")) }
        expect(messages.join("\n")).to contain("200 MISS  GET 127.0.0.1:#{port}/pool/main/pkg.deb")
      end
    end

    it "tags a failure answered with a status below 500 with ERR" do
      messages = captured_messages { proxy.handle(make_ctx("GET", "/")) }
      expect(messages.join("\n")).to contain("400 ERR   GET /")
    end

    it "tags a failure answered with a status of 500 or above with FAIL" do
      port = closed_port
      messages = captured_messages { proxy.handle(make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/pkg.deb")) }
      expect(messages.join("\n")).to contain("502 FAIL  GET 127.0.0.1:#{port}/pool/main/pkg.deb")
    end

    it "logs the MISS but not the HIT that follows when quiet" do
      quiet_proxy = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 5,
        connect_timeout: 10, read_timeout: 30, quiet: true, allow_local_targets: true)
      with_local_server do |port, _|
        messages = captured_messages do
          2.times { quiet_proxy.handle(make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/pkg.deb")) }
        end
        access_lines = messages.select(&.includes?(" GET "))

        # The second request was a HIT, and it left no line.
        expect(quiet_proxy.stats[:hits]).to eq(1)
        expect(access_lines.size).to eq(1)
        expect(access_lines.join("\n")).to contain("200 MISS  GET 127.0.0.1:#{port}/pool/main/pkg.deb")
      end
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

      reval_proxy = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30, allow_local_targets: true)
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
    it "returns 502 and invalidates the entry when upstream cannot provide it again" do
      key = "127.0.0.1:#{closed_port}/pool/main/pkg.deb"
      store(key, "data")
      expect(cache.exists?(key)).to be_true

      FileUtils.rm_rf(tmp_dir)

      ctx = make_ctx("GET", "/#{key}")
      proxy.handle(ctx)

      expect(ctx.response.status_code).to eq(502)
      expect(cache.exists?(key)).to be_false
    end

    it "downloads the file again within the same request when upstream has it" do
      handler = ->(ctx : HTTP::Server::Context) { ctx.response.print("fresh copy") }
      with_upstream(handler) do |port|
        key = "127.0.0.1:#{port}/pool/main/pkg.deb"
        store(key, "data")
        File.delete(File.join(tmp_dir, key))

        ctx = make_ctx("GET", "/#{key}")
        proxy.handle(ctx)

        expect(ctx.response.status_code).to eq(200)
        expect(response_body(ctx)).to eq("fresh copy")
        expect(File.read(File.join(tmp_dir, key))).to eq("fresh copy")
      end
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
    private def make_range_ctx(range : String, method : String = "GET",
                               if_range : String? = nil) : HTTP::Server::Context
      headers = HTTP::Headers{"Range" => range}
      headers["If-Range"] = if_range if if_range
      req = HTTP::Request.new(method, "/mirror/pool/main/pkg.deb", headers)
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
      expect(response_body(ctx)).to eq("2345")
    end

    it "handles open-ended range bytes=N-" do
      ctx = make_range_ctx("bytes=7-")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(206)
      expect(ctx.response.headers["Content-Range"]).to eq("bytes 7-9/10")
      expect(response_body(ctx)).to eq("789")
    end

    it "handles suffix range bytes=-N" do
      ctx = make_range_ctx("bytes=-3")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(206)
      expect(ctx.response.headers["Content-Range"]).to eq("bytes 7-9/10")
      expect(response_body(ctx)).to eq("789")
    end

    it "clamps a range running past the end of the file" do
      ctx = make_range_ctx("bytes=8-30")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(206)
      expect(ctx.response.headers["Content-Range"]).to eq("bytes 8-9/10")
      expect(response_body(ctx)).to eq("89")
    end

    it "answers a HEAD with the range headers and no body" do
      ctx = make_range_ctx("bytes=2-5", method: "HEAD")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(206)
      expect(ctx.response.headers["Content-Range"]).to eq("bytes 2-5/10")
      expect(response_body(ctx)).to eq("")
    end

    # RFC 9110 §15.5.17: a range starting at or beyond the end is unsatisfiable.
    it "answers 416 to a range starting beyond the end of the file" do
      ctx = make_range_ctx("bytes=20-30")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(416)
      expect(ctx.response.headers["Content-Range"]).to eq("bytes */10")
    end

    it "answers 416 to a range starting exactly at the end of the file" do
      ctx = make_range_ctx("bytes=10-")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(416)
      expect(ctx.response.headers["Content-Range"]).to eq("bytes */10")
    end

    it "answers 416 to a zero-length suffix range bytes=-0" do
      ctx = make_range_ctx("bytes=-0")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(416)
    end

    it "ignores a syntactically invalid range and serves the whole file" do
      ["bytes=5-2", "bytes=a-b", "items=0-1", "bytes=0-1,4-5"].each do |range|
        ctx = make_range_ctx(range)
        proxy.handle(ctx)
        expect(ctx.response.status_code).to eq(200)
        expect(response_body(ctx)).to eq("0123456789")
      end
    end

    # The proxy keeps no validator to compare If-Range with: the only answer
    # that cannot splice two versions of a file together is the whole file.
    it "serves the whole file when the range is conditional (If-Range)" do
      ctx = make_range_ctx("bytes=2-5", if_range: "Wed, 21 Oct 2015 07:28:00 GMT")
      proxy.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(response_body(ctx)).to eq("0123456789")
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

    # Integration test over a real TCP socket: the buffered copy writes into
    # the output of a live HTTP::Server, and the body is read back by an HTTP
    # client rather than out of an IO::Memory.
    it "serves a HIT correctly over a real TCP socket (buffered copy)" do
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
    # Servers actually started by the example. Closing `fake_upstream`
    # directly would start one in every example that never asked for it.
    let(started_upstreams) { [] of HTTP::Server }
    let(fake_upstream) do
      server = HTTP::Server.new do |ctx|
        ctx.response.content_type = "application/octet-stream"
        ctx.response.print("upstream content")
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield
      started_upstreams << server
      {server, addr.port}
    end

    after_each { started_upstreams.each(&.close) }

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

      # Built here, not in the fibers: `proxy` and `cache` are lazy, and three
      # threads evaluating them at once race on creating the cache directory.
      target = proxy
      done = Channel(Int32).new
      3.times do
        spawn do
          ctx = make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/pkg.deb")
          target.handle(ctx)
          done.send(ctx.response.status_code)
        end
      end

      statuses = 3.times.map { done.receive }.to_a
      server.close

      expect(request_count).to eq(1)
      expect(statuses).to all(eq(200))
    end

    # A failed flight has no file to share: its waiters must be handed the
    # leader's status, not go and ask upstream again, nor fall back to 502.
    #
    # The leader is held inside its upstream request until both waiters have
    # entered the flight, so the three requests really overlap.
    it "single-flight: 3 concurrent requests for a missing file share one upstream 404" do
      requests = Atomic(Int32).new(0)
      arrived = Channel(Nil).new(3)
      release = Channel(Nil).new
      handler = ->(ctx : HTTP::Server::Context) do
        requests.add(1)
        arrived.send(nil)
        release.receive?
        ctx.response.status = HTTP::Status::NOT_FOUND
      end

      flight = AptLarder::SingleFlight.new
      target = AptLarder::Proxy.new(cache, flight, max_redirects: 5, index_ttl: 5,
        connect_timeout: 10, read_timeout: 30, allow_local_targets: true)

      with_upstream(handler) do |port|
        done = Channel(Int32).new(3)
        request = -> do
          ctx = make_ctx("GET", "http://127.0.0.1:#{port}/pool/main/missing.deb")
          target.handle(ctx)
          done.send(ctx.response.status_code)
        end

        # The leader first, up to the point where upstream holds its request.
        spawn { request.call }
        arrived.receive

        # Then both waiters, until they have joined the leader's flight: a
        # waiter arriving after the flight ended would ask upstream again.
        2.times { spawn { request.call } }
        key = "127.0.0.1:#{port}/pool/main/missing.deb"
        wait_until("both waiters joined the flight") { flight.waiters(key) == 2 }
        release.close
        statuses = Array(Int32).new(3) { done.receive }

        expect(statuses).to eq([404, 404, 404])
        expect(requests.get).to eq(1)
      end
    end
  end

  describe "revalidation (304)" do
    let(reval_proxy) { AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30, allow_local_targets: true) }

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
    # Servers actually started by the example. Closing `fake_upstream`
    # directly would start one in every example that never asked for it.
    let(started_upstreams) { [] of HTTP::Server }
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
      started_upstreams << server
      {server, addr.port}
    end

    after_each { started_upstreams.each(&.close) }

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
      reval_proxy = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30, allow_local_targets: true)

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
      reval_proxy = AptLarder::Proxy.new(cache, AptLarder::SingleFlight.new, max_redirects: 5, index_ttl: 0, connect_timeout: 10, read_timeout: 30, allow_local_targets: true)

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

    # "upstream body" is 13 bytes: the length announced upstream is announced
    # to the client, and nothing follows the headers.
    it "answers a HEAD with the upstream Content-Length and no body" do
      _, port = fake_upstream

      ctx = make_ctx("HEAD", "http://127.0.0.1:#{port}/images/disk.iso.sha256")
      proxy.handle(ctx)

      expect(ctx.response.status_code).to eq(200)
      expect(ctx.response.headers["Content-Length"]).to eq("13")
      expect(response_body(ctx)).to eq("")
      expect(proxy.stats[:bytes]).to eq(0)
    end

    it "relays the upstream Content-Type" do
      _, port = fake_upstream

      ctx = make_ctx("GET", "http://127.0.0.1:#{port}/images/disk.iso.sha256")
      proxy.handle(ctx)

      expect(ctx.response.headers["Content-Type"]).to eq("text/plain")
    end

    it "answers 502 when upstream is unreachable" do
      ctx = make_ctx("GET", "http://127.0.0.1:#{closed_port}/images/disk.iso.sha256")
      proxy.handle(ctx)

      expect(ctx.response.status_code).to eq(502)
      expect(proxy.stats[:errors]).to eq(1)
    end
  end

  describe "redirect following" do
    # Starts an upstream that answers *status* on /redirect, with the Location
    # built by *location* from the port it listens on (none when nil), and a
    # package on every other path. Yields the port and the resources received.
    private def with_redirecting_upstream(status : Int32, location : (Int32 -> String)?, &)
      resources = [] of String
      bound = [0]
      handler = ->(ctx : HTTP::Server::Context) do
        resources << ctx.request.resource
        if ctx.request.path == "/redirect"
          ctx.response.status_code = status
          if build = location
            ctx.response.headers["Location"] = build.call(bound[0])
          end
        else
          ctx.response.content_type = "application/octet-stream"
          ctx.response.print("final content")
        end
      end
      with_upstream(handler) do |port|
        bound[0] = port
        yield port, resources
      end
    end

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
    #
    # The status alone cannot show it: a poisoned pooled connection is retried
    # on a fresh one and the request still succeeds. What the drain buys is
    # that no second connection is needed, so that is what is counted, on a
    # raw server that keeps every connection alive.
    it "drains the 301 body so the redirect and the final request share one connection" do
      html = "<html>\n<head><title>301 Moved Permanently</title></head>\n</html>\n"
      accepted = Atomic(Int32).new(0)
      peers = [] of TCPSocket
      tcp = TCPServer.new("127.0.0.1", 0)
      port = tcp.local_address.port

      spawn do
        while sock = tcp.accept?
          accepted.add(1)
          peers << sock
          csock = sock
          spawn do
            # Serves every request the client sends on this connection.
            while request_line = csock.gets
              while (line = csock.gets) && !line.empty?; end
              if request_line.starts_with?("GET /redirect ")
                csock << "HTTP/1.1 301 Moved Permanently\r\nLocation: http://127.0.0.1:#{port}/final/pkg.deb\r\n"
                csock << "Content-Type: text/html\r\nContent-Length: #{html.bytesize}\r\nConnection: keep-alive\r\n\r\n" << html
              else
                csock << "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 13\r\nConnection: keep-alive\r\n\r\nfinal content"
              end
              csock.flush
            end
          rescue IO::Error
          end
        end
      end

      begin
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/redirect")
        proxy.handle(ctx)

        expect(ctx.response.status_code).to eq(200)
        expect(response_body(ctx)).to eq("final content")
        expect(accepted.get).to eq(1)
      ensure
        tcp.close
        peers.each(&.close)
      end
    end

    {% for status in [302, 303, 307, 308] %}
    it "follows a {{status.id}} redirect to the final resource" do
      absolute = ->(port : Int32) { "http://127.0.0.1:#{port}/final/pkg.deb" }
      with_redirecting_upstream({{status}}, absolute) do |port, resources|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/redirect")
        proxy.handle(ctx)

        expect(ctx.response.status_code).to eq(200)
        expect(response_body(ctx)).to eq("final content")
        expect(resources).to eq(["/redirect", "/final/pkg.deb"])
      end
    end
    {% end %}

    it "resolves a relative Location against the URL being fetched" do
      relative = ->(_port : Int32) { "/final/pkg.deb" }
      with_redirecting_upstream(301, relative) do |port, resources|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/redirect")
        proxy.handle(ctx)

        expect(ctx.response.status_code).to eq(200)
        expect(response_body(ctx)).to eq("final content")
        expect(resources).to eq(["/redirect", "/final/pkg.deb"])
      end
    end

    # Signed CDN URLs: the token lives in the query string of the Location.
    it "sends the query string of the Location to the final server" do
      signed = ->(port : Int32) { "http://127.0.0.1:#{port}/final/pkg.deb?token=abc&exp=1" }
      with_redirecting_upstream(302, signed) do |port, resources|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/redirect")
        proxy.handle(ctx)

        expect(ctx.response.status_code).to eq(200)
        expect(resources).to eq(["/redirect", "/final/pkg.deb?token=abc&exp=1"])
      end
    end

    # Without a Location there is nowhere to go, and a 3xx is not a file.
    it "answers 502 to a redirect without Location and caches nothing" do
      with_redirecting_upstream(302, nil) do |port, resources|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/redirect")
        proxy.handle(ctx)

        expect(ctx.response.status_code).to eq(502)
        expect(resources).to eq(["/redirect"])
        expect(cache.exists?("127.0.0.1:#{port}/redirect")).to be_false
      end
    end

    # max_redirects is 5: the first request plus five followed redirects, and
    # the sixth redirect is the one refused.
    it "stops an endless redirect loop after 6 upstream requests and answers 502" do
      looping = ->(_port : Int32) { "/redirect" }
      with_redirecting_upstream(301, looping) do |port, resources|
        ctx = make_ctx("GET", "http://127.0.0.1:#{port}/redirect")
        proxy.handle(ctx)

        expect(ctx.response.status_code).to eq(502)
        expect(resources.size).to eq(6)
        expect(cache.exists?("127.0.0.1:#{port}/redirect")).to be_false
      end
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
