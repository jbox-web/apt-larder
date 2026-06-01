require "./spec_helper"
require "file_utils"
require "base64"

Spectator.describe "Admin auth middleware" do
  let(tmp_dir) { "/tmp/apt-larder-auth-#{Random::Secure.hex(4)}" }
  let(cache) { AptLarder::Cache.new(tmp_dir) }
  let(sf) { AptLarder::SingleFlight.new }
  let(proxy) { AptLarder::Proxy.new(cache, sf, max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30) }

  after_each { FileUtils.rm_rf(tmp_dir) }

  private def make_ctx(method : String, path : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Server::Context
    req = HTTP::Request.new(method, path, headers)
    res = HTTP::Server::Response.new(IO::Memory.new)
    HTTP::Server::Context.new(req, res)
  end

  describe "API Bearer token auth" do
    let(config) do
      c = AptLarder::AdminConfig.from_yaml("")
      c.api_token = "mysecret"
      c
    end
    let(server) { AptLarder::Admin::Server.new(config, cache, proxy) }

    it "returns 401 when token is missing" do
      ctx = make_ctx("GET", "/api/health")
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(401)
    end

    it "returns 401 when token is wrong" do
      h = HTTP::Headers{"Authorization" => "Bearer wrong"}
      ctx = make_ctx("GET", "/api/health", h)
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(401)
    end

    it "passes through with correct token" do
      h = HTTP::Headers{"Authorization" => "Bearer mysecret"}
      ctx = make_ctx("GET", "/api/health", h)
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "passes through when no token is configured" do
      open_config = AptLarder::AdminConfig.from_yaml("")
      open_server = AptLarder::Admin::Server.new(open_config, cache, proxy)
      ctx = make_ctx("GET", "/api/health")
      open_server.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end
  end

  describe "UI Basic Auth" do
    let(config) do
      c = AptLarder::AdminConfig.from_yaml("")
      c.ui_user = "admin"
      c.ui_password = "pass"
      c
    end
    let(server) { AptLarder::Admin::Server.new(config, cache, proxy) }

    it "returns 401 when credentials are missing" do
      ctx = make_ctx("GET", "/")
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(401)
      expect(ctx.response.headers["WWW-Authenticate"]).to eq(%(Basic realm="apt-larder admin"))
    end

    it "returns 401 with wrong password" do
      creds = Base64.strict_encode("admin:wrong")
      h = HTTP::Headers{"Authorization" => "Basic #{creds}"}
      ctx = make_ctx("GET", "/", h)
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(401)
    end

    it "passes through with correct credentials" do
      creds = Base64.strict_encode("admin:pass")
      h = HTTP::Headers{"Authorization" => "Basic #{creds}"}
      ctx = make_ctx("GET", "/", h)
      server.handle(ctx)
      expect(ctx.response.status_code).not_to eq(401)
    end
  end
end
