require "./spec_helper"
require "file_utils"

Spectator.describe AptLarder::Admin::Api do
  let(tmp_dir) { spec_tmp_dir("admin") }
  let(cache) { AptLarder::Cache.new(tmp_dir) }
  let(sf) { AptLarder::SingleFlight.new }
  let(proxy) { AptLarder::Proxy.new(cache, sf, max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30) }
  let(api) { AptLarder::Admin::Api.new(cache, proxy) }

  after_each { FileUtils.rm_rf(tmp_dir) }

  private def make_ctx(method : String, path : String, body : String = "",
                       headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Server::Context
    unless body.empty?
      headers["Content-Length"] = body.bytesize.to_s
      headers["Content-Type"] = "application/json" unless headers.has_key?("Content-Type")
    end
    req = HTTP::Request.new(method, path, headers, body)
    res = HTTP::Server::Response.new(IO::Memory.new)
    HTTP::Server::Context.new(req, res)
  end

  private def response_body(ctx : HTTP::Server::Context) : String
    io = ctx.response.@io.as(IO::Memory)
    io.rewind
    raw = io.gets_to_end
    raw.split("\r\n\r\n", 2).last? || ""
  end

  describe "GET /api/health" do
    it "returns status ok and version" do
      ctx = make_ctx("GET", "/api/health")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      json = JSON.parse(response_body(ctx))
      expect(json["status"].as_s).to eq("ok")
      expect(json["version"].as_s).not_to be_empty
    end
  end

  describe "GET /api/stats" do
    it "returns all stat counters" do
      ctx = make_ctx("GET", "/api/stats")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      json = JSON.parse(response_body(ctx))
      expect(json["hits"].as_i64).to eq(0)
      expect(json.as_h.keys.sort!).to eq(["bytes", "cache_bytes", "errors", "hits", "misses", "revalidations", "tunnels"])
    end

    it "reports the disk space used by the cache" do
      cache.store("mirror/pool/main/pkg.deb", IO::Memory.new("data".to_slice))
      ctx = make_ctx("GET", "/api/stats")
      api.handle(ctx)
      json = JSON.parse(response_body(ctx))
      expect(json["cache_bytes"].as_i64).to eq(4)
    end
  end

  describe "GET /api/cache" do
    it "returns empty list when cache is empty" do
      ctx = make_ctx("GET", "/api/cache")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      json = JSON.parse(response_body(ctx))
      expect(json["total"].as_i).to eq(0)
      expect(json["entries"].as_a).to be_empty
    end

    it "lists cached entries" do
      cache.store("mirror/pool/main/pkg.deb", IO::Memory.new("data".to_slice))
      ctx = make_ctx("GET", "/api/cache")
      api.handle(ctx)
      json = JSON.parse(response_body(ctx))
      expect(json["total"].as_i).to eq(1)
      expect(json["entries"][0]["key"].as_s).to eq("mirror/pool/main/pkg.deb")
    end
  end

  describe "GET /api/cache search and sort" do
    private def list_keys(query : String) : Array(String)
      ctx = make_ctx("GET", "/api/cache?#{query}")
      api.handle(ctx)
      JSON.parse(response_body(ctx))["entries"].as_a.map(&.["key"].as_s)
    end

    before_each do
      cache.store("mirror/pool/main/c/curl_8_amd64.deb", IO::Memory.new("xx".to_slice))
      cache.store("mirror/pool/main/p/php_8_amd64.deb", IO::Memory.new("xxxxx".to_slice))
      cache.store("mirror/pool/main/z/zsh_5_amd64.deb", IO::Memory.new("x".to_slice))
    end

    it "filters entries by search term and reports the filtered total" do
      ctx = make_ctx("GET", "/api/cache?search=PHP")
      api.handle(ctx)
      json = JSON.parse(response_body(ctx))
      expect(json["total"].as_i).to eq(1)
      expect(json["entries"].as_a.map(&.["key"].as_s)).to eq(["mirror/pool/main/p/php_8_amd64.deb"])
    end

    it "sorts by size descending" do
      expect(list_keys("sort=size&order=desc")).to eq([
        "mirror/pool/main/p/php_8_amd64.deb",
        "mirror/pool/main/c/curl_8_amd64.deb",
        "mirror/pool/main/z/zsh_5_amd64.deb",
      ])
    end

    it "sorts by key descending" do
      expect(list_keys("order=desc")).to eq([
        "mirror/pool/main/z/zsh_5_amd64.deb",
        "mirror/pool/main/p/php_8_amd64.deb",
        "mirror/pool/main/c/curl_8_amd64.deb",
      ])
    end

    it "falls back to key ascending on unknown sort and order values" do
      expect(list_keys("sort=bogus&order=sideways")).to eq([
        "mirror/pool/main/c/curl_8_amd64.deb",
        "mirror/pool/main/p/php_8_amd64.deb",
        "mirror/pool/main/z/zsh_5_amd64.deb",
      ])
    end
  end

  describe "GET /api/cache parameters" do
    before_each do
      cache.store("a/one.deb", IO::Memory.new("1".to_slice))
      cache.store("a/two.deb", IO::Memory.new("22".to_slice))
      cache.store("b/three.deb", IO::Memory.new("333".to_slice))
    end

    private def list(query : String) : JSON::Any
      ctx = make_ctx("GET", "/api/cache?#{query}")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      JSON.parse(response_body(ctx))
    end

    private def keys(json : JSON::Any) : Array(String)
      json["entries"].as_a.map(&.["key"].as_s)
    end

    it "caps per_page at 200 and echoes the value it applied" do
      json = list("per_page=500")
      expect(json["per_page"].as_i).to eq(200)
      expect(json["total"].as_i).to eq(3)
    end

    it "treats page 0 and a negative page as page 1, and echoes it" do
      expect(list("page=0")["page"].as_i).to eq(1)
      expect(list("page=-3")["page"].as_i).to eq(1)
    end

    it "pages through the entries" do
      expect(keys(list("per_page=2&page=1"))).to eq(["a/one.deb", "a/two.deb"])
      expect(keys(list("per_page=2&page=2"))).to eq(["b/three.deb"])
    end

    it "returns an empty page beyond the last one, however far" do
      expect(keys(list("per_page=2&page=3"))).to be_empty
      json = list("per_page=200&page=2147483647")
      expect(keys(json)).to be_empty
      expect(json["total"].as_i).to eq(3)
    end

    it "filters by prefix" do
      expect(keys(list("prefix=a%2F"))).to eq(["a/one.deb", "a/two.deb"])
    end

    it "sorts by size, descending on request" do
      expect(keys(list("sort=size&order=desc"))).to eq(["b/three.deb", "a/two.deb", "a/one.deb"])
    end

    it "sorts by mtime" do
      past = Time.utc - 2.days
      File.utime(past, past, File.join(tmp_dir, "b/three.deb"))
      expect(keys(list("sort=mtime")).first).to eq("b/three.deb")
    end
  end

  describe "unknown routes" do
    it "answers 404 with a JSON error" do
      ctx = make_ctx("GET", "/api/nope")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(404)
      expect(JSON.parse(response_body(ctx))["error"].as_s).to eq("not found")
    end
  end

  describe "DELETE /api/cache" do
    it "flushes all entries and returns count" do
      cache.store("a/pkg.deb", IO::Memory.new("x".to_slice))
      cache.store("b/pkg.deb", IO::Memory.new("y".to_slice))
      ctx = make_ctx("DELETE", "/api/cache")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      json = JSON.parse(response_body(ctx))
      expect(json["deleted"].as_i).to eq(2)
    end
  end

  describe "DELETE /api/cache/:key" do
    it "invalidates a specific entry" do
      cache.store("mirror/pool/main/pkg.deb", IO::Memory.new("data".to_slice))
      ctx = make_ctx("DELETE", "/api/cache/mirror%2Fpool%2Fmain%2Fpkg.deb")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(204)
      expect(cache.exists?("mirror/pool/main/pkg.deb")).to be_false
    end

    it "returns 404 for unknown key" do
      ctx = make_ctx("DELETE", "/api/cache/unknown%2Fkey.deb")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(404)
    end

    # Deleting only the .sha256 sidecar would leave the .deb in place with no
    # sidecar, which valid? then trusts: the file would be served unverified.
    it "rejects a sidecar key with 400 and leaves the entry intact" do
      cache.store("mirror/pool/main/pkg.deb", IO::Memory.new("data".to_slice))
      ctx = make_ctx("DELETE", "/api/cache/mirror%2Fpool%2Fmain%2Fpkg.deb.sha256")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
      expect(File.exists?(File.join(tmp_dir, "mirror/pool/main/pkg.deb.sha256"))).to be_true
    end

    it "answers 404 for a directory, which holds entries but is not one" do
      cache.store("mirror/pool/main/pkg.deb", IO::Memory.new("data".to_slice))
      ctx = make_ctx("DELETE", "/api/cache/mirror%2Fpool")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(404)
      expect(cache.exists?("mirror/pool/main/pkg.deb")).to be_true
    end

    # Such a file is a download in flight: deleting it fails that download.
    it "rejects the name of a temporary download file with 400" do
      # The cache must exist first: opening it purges the temporary files a
      # previous run left behind.
      cache.store("mirror/pkg.deb", IO::Memory.new("data".to_slice))
      path = File.join(tmp_dir, "mirror/other.deb.0123456789abcdef.tmp")
      File.write(path, "half a download")
      ctx = make_ctx("DELETE", "/api/cache/mirror%2Fother.deb.0123456789abcdef.tmp")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
      expect(File.exists?(path)).to be_true
    end

    it "rejects path traversal with 400 (guard fires before invalidate)" do
      # decodes to "../../etc/passwd" — must be refused before any fs access
      ctx = make_ctx("DELETE", "/api/cache/..%2F..%2Fetc%2Fpasswd")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
    end
  end

  describe "POST /api/evict" do
    it "runs eviction and returns counts" do
      cache.store("old.deb", IO::Memory.new("x".to_slice))
      path = File.join(tmp_dir, "old.deb")
      past = Time.utc - 8.days
      File.utime(past, past, path)
      ctx = make_ctx("POST", "/api/evict", %({"max_age_days": 7}))
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      json = JSON.parse(response_body(ctx))
      expect(json["deleted"].as_i).to eq(1)
      expect(json["freed_bytes"].as_i64).to be > 0_i64
    end

    it "falls back to the configured age when no body is sent" do
      cache.store("old.deb", IO::Memory.new("x".to_slice))
      cache.store("recent.deb", IO::Memory.new("y".to_slice))
      past = Time.utc - 31.days
      File.utime(past, past, File.join(tmp_dir, "old.deb"))
      ctx = make_ctx("POST", "/api/evict")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(JSON.parse(response_body(ctx))["deleted"].as_i).to eq(1)
      expect(File.exists?(File.join(tmp_dir, "recent.deb"))).to be_true
    end

    # evict_after_days: 0 means "eviction disabled", never "evict everything".
    context "when the configured age is 0 (eviction disabled)" do
      let(api) { AptLarder::Admin::Api.new(cache, proxy, 0) }

      it "deletes nothing when no body is sent" do
        cache.store("pkg.deb", IO::Memory.new("x".to_slice))
        past = Time.utc - 400.days
        File.utime(past, past, File.join(tmp_dir, "pkg.deb"))
        ctx = make_ctx("POST", "/api/evict")
        api.handle(ctx)
        expect(ctx.response.status_code).to eq(200)
        json = JSON.parse(response_body(ctx))
        expect(json["deleted"].as_i).to eq(0)
        expect(json["freed_bytes"].as_i64).to eq(0_i64)
        expect(File.exists?(File.join(tmp_dir, "pkg.deb"))).to be_true
      end
    end

    it "rejects max_age_days 0 with 400 and leaves the cache intact" do
      cache.store("pkg.deb", IO::Memory.new("x".to_slice))
      ctx = make_ctx("POST", "/api/evict", %({"max_age_days": 0}))
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
      expect(File.exists?(File.join(tmp_dir, "pkg.deb"))).to be_true
    end

    it "rejects a negative max_age_days with 400 and leaves the cache intact" do
      cache.store("pkg.deb", IO::Memory.new("x".to_slice))
      ctx = make_ctx("POST", "/api/evict", %({"max_age_days": -5}))
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
      expect(File.exists?(File.join(tmp_dir, "pkg.deb"))).to be_true
    end

    it "rejects a body that is not valid JSON with 400" do
      cache.store("pkg.deb", IO::Memory.new("x".to_slice))
      ctx = make_ctx("POST", "/api/evict", "max_age_days=0")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(400)
      expect(File.exists?(File.join(tmp_dir, "pkg.deb"))).to be_true
    end

    # A cross-site form or fetch can only send text/plain, urlencoded or
    # multipart without a preflight: requiring JSON closes that door.
    it "rejects a body that is not declared as JSON with 415" do
      cache.store("pkg.deb", IO::Memory.new("x".to_slice))
      past = Time.utc - 8.days
      File.utime(past, past, File.join(tmp_dir, "pkg.deb"))
      ctx = make_ctx("POST", "/api/evict", %({"max_age_days": 7}),
        HTTP::Headers{"Content-Type" => "text/plain"})
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(415)
      expect(File.exists?(File.join(tmp_dir, "pkg.deb"))).to be_true
    end
  end

  describe "cross-origin requests" do
    it "rejects a state-changing request whose Origin is another site with 403" do
      cache.store("pkg.deb", IO::Memory.new("x".to_slice))
      ctx = make_ctx("DELETE", "/api/cache",
        headers: HTTP::Headers{"Host" => "127.0.0.1:8080", "Origin" => "http://evil.example"})
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(403)
      expect(File.exists?(File.join(tmp_dir, "pkg.deb"))).to be_true
    end

    it "accepts a state-changing request whose Origin is the admin server itself" do
      cache.store("pkg.deb", IO::Memory.new("x".to_slice))
      ctx = make_ctx("DELETE", "/api/cache",
        headers: HTTP::Headers{"Host" => "127.0.0.1:8080", "Origin" => "http://127.0.0.1:8080"})
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(File.exists?(File.join(tmp_dir, "pkg.deb"))).to be_false
    end

    it "lets a read through whatever its Origin" do
      ctx = make_ctx("GET", "/api/health",
        headers: HTTP::Headers{"Host" => "127.0.0.1:8080", "Origin" => "http://evil.example"})
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end
  end

  describe "GET /api/metrics" do
    it "returns Prometheus text format with all metric families" do
      ctx = make_ctx("GET", "/api/metrics")
      api.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      body = response_body(ctx)
      expect(body).to contain("apt_larder_hits_total")
      expect(body).to contain("apt_larder_misses_total")
      expect(body).to contain("apt_larder_bytes_served_total")
      expect(body).to contain("apt_larder_cache_entries")
      expect(body).to contain("# TYPE apt_larder_hits_total counter")
      expect(body).to contain("# TYPE apt_larder_cache_entries gauge")
      expect(body).to contain("# TYPE apt_larder_cache_bytes gauge")
    end

    it "exposes exactly the documented metric families, as Prometheus text" do
      ctx = make_ctx("GET", "/api/metrics")
      api.handle(ctx)
      expect(ctx.response.headers["Content-Type"]).to eq("text/plain; version=0.0.4")
      types = response_body(ctx).lines.select(&.starts_with?("# TYPE ")).map(&.lchop("# TYPE "))
      expect(types).to eq([
        "apt_larder_hits_total counter",
        "apt_larder_misses_total counter",
        "apt_larder_revalidations_total counter",
        "apt_larder_errors_total counter",
        "apt_larder_bytes_served_total counter",
        "apt_larder_tunnels_total counter",
        "apt_larder_cache_entries gauge",
        "apt_larder_cache_bytes gauge",
      ])
    end

    it "reflects actual stats values" do
      cache.store("mirror/pool/main/pkg.deb", IO::Memory.new("data".to_slice))
      ctx = make_ctx("GET", "/api/metrics")
      api.handle(ctx)
      body = response_body(ctx)
      expect(body).to contain("apt_larder_cache_entries 1")
      expect(body).to contain("apt_larder_cache_bytes 4\n")
    end
  end
end
