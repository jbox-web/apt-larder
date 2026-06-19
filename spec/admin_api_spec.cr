require "./spec_helper"
require "file_utils"

Spectator.describe AptLarder::Admin::Api do
  let(tmp_dir) { "/tmp/apt-larder-admin-#{Random::Secure.hex(4)}" }
  let(cache) { AptLarder::Cache.new(tmp_dir) }
  let(sf) { AptLarder::SingleFlight.new }
  let(proxy) { AptLarder::Proxy.new(cache, sf, max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30) }
  let(api) { AptLarder::Admin::Api.new(cache, proxy) }

  after_each { FileUtils.rm_rf(tmp_dir) }

  private def make_ctx(method : String, path : String, body : String = "") : HTTP::Server::Context
    headers = HTTP::Headers.new
    headers["Content-Length"] = body.bytesize.to_s unless body.empty?
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
      expect(json.as_h.keys.sort!).to eq(["bytes", "errors", "hits", "misses", "revalidations", "tunnels"])
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
    end

    it "reflects actual stats values" do
      cache.store("mirror/pool/main/pkg.deb", IO::Memory.new("data".to_slice))
      ctx = make_ctx("GET", "/api/metrics")
      api.handle(ctx)
      body = response_body(ctx)
      expect(body).to contain("apt_larder_cache_entries 1")
    end
  end
end
