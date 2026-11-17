require "./spec_helper"
require "file_utils"
require "base64"

Spectator.describe "Admin auth middleware" do
  let(tmp_dir) { spec_tmp_dir("auth") }
  let(cache) { AptLarder::Cache.new(tmp_dir) }
  let(sf) { AptLarder::SingleFlight.new }
  let(proxy) { AptLarder::Proxy.new(cache, sf, max_redirects: 5, index_ttl: 5, connect_timeout: 10, read_timeout: 30) }

  after_each { FileUtils.rm_rf(tmp_dir) }

  private def make_ctx(method : String, path : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Server::Context
    req = HTTP::Request.new(method, path, headers)
    res = HTTP::Server::Response.new(IO::Memory.new)
    HTTP::Server::Context.new(req, res)
  end

  private def basic(user : String, password : String) : HTTP::Headers
    HTTP::Headers{"Authorization" => "Basic #{Base64.strict_encode("#{user}:#{password}")}"}
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
      expect(ctx.response.headers["WWW-Authenticate"]).to eq(%(Bearer realm="apt-larder api"))
    end

    it "returns 401 to Basic credentials when only a token is configured" do
      ctx = make_ctx("GET", "/api/health", basic("admin", "pass"))
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
      ctx = make_ctx("GET", "/", basic("admin", "pass"))
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "returns 401 with the right password under another user name" do
      ctx = make_ctx("GET", "/", basic("root", "pass"))
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(401)
    end

    it "returns 401 when the credentials are not valid Base64" do
      ctx = make_ctx("GET", "/", HTTP::Headers{"Authorization" => "Basic %%%"})
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(401)
    end

    # The UI credentials guard the API the UI drives: without them, protecting
    # the pages while leaving DELETE /api/cache open protects nothing.
    context "on the API" do
      it "returns 401 when no credentials are sent" do
        ctx = make_ctx("DELETE", "/api/cache")
        server.handle(ctx)
        expect(ctx.response.status_code).to eq(401)
      end

      it "returns 401 with a wrong password" do
        ctx = make_ctx("GET", "/api/health", basic("admin", "wrong"))
        server.handle(ctx)
        expect(ctx.response.status_code).to eq(401)
      end

      it "returns 401 with the right password under another user name" do
        ctx = make_ctx("GET", "/api/health", basic("root", "pass"))
        server.handle(ctx)
        expect(ctx.response.status_code).to eq(401)
      end

      it "passes through with the UI credentials" do
        ctx = make_ctx("GET", "/api/health", basic("admin", "pass"))
        server.handle(ctx)
        expect(ctx.response.status_code).to eq(200)
      end
    end
  end

  describe "token and UI credentials together" do
    let(config) do
      c = AptLarder::AdminConfig.from_yaml("")
      c.api_token = "mysecret"
      c.ui_user = "admin"
      c.ui_password = "pass"
      c
    end
    let(server) { AptLarder::Admin::Server.new(config, cache, proxy) }

    it "accepts the token on the API" do
      ctx = make_ctx("GET", "/api/health", HTTP::Headers{"Authorization" => "Bearer mysecret"})
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "accepts the UI credentials on the API" do
      ctx = make_ctx("GET", "/api/health", basic("admin", "pass"))
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
    end

    it "returns 401 on the API without either" do
      ctx = make_ctx("GET", "/api/health")
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(401)
    end

    it "does not accept the token on the UI pages" do
      ctx = make_ctx("GET", "/", HTTP::Headers{"Authorization" => "Bearer mysecret"})
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(401)
    end
  end

  describe "embedded assets" do
    let(server) { AptLarder::Admin::Server.new(AptLarder::AdminConfig.from_yaml(""), cache, proxy) }

    it "serves the page shell as HTML" do
      ctx = make_ctx("GET", "/")
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(ctx.response.headers["Content-Type"]).to eq("text/html")
    end

    it "serves the script as JavaScript" do
      ctx = make_ctx("GET", "/admin.js")
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(ctx.response.headers["Content-Type"]).to eq("application/javascript")
    end

    it "serves the stylesheet as CSS" do
      ctx = make_ctx("GET", "/admin.css")
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(ctx.response.headers["Content-Type"]).to eq("text/css")
    end

    private def body_of(ctx : HTTP::Server::Context) : String
      ctx.response.flush
      ctx.response.@io.as(IO::Memory).to_s.split("\r\n\r\n", 2)[1]? || ""
    end

    # The UI must work on a network with no Internet access, and must not run
    # code fetched from a third party on the admin origin.
    it "serves the libraries it depends on itself" do
      {
        "/vendor/jquery.min.js"      => {"application/javascript", "jQuery v3.7.1"},
        "/vendor/dataTables.min.js"  => {"application/javascript", "DataTables 2.1.8"},
        "/vendor/dataTables.min.css" => {"text/css", "table.dataTable"},
      }.each do |path, (content_type, marker)|
        ctx = make_ctx("GET", path)
        server.handle(ctx)
        expect(ctx.response.status_code).to eq(200)
        expect(ctx.response.headers["Content-Type"]).to eq(content_type)
        expect(body_of(ctx)).to contain(marker)
      end
    end

    it "references no resource outside its own origin" do
      ctx = make_ctx("GET", "/")
      server.handle(ctx)
      page = body_of(ctx)
      expect(page).not_to contain("https://")
      expect(page).not_to contain("http://")
      expect(page).to contain(%(src="/vendor/jquery.min.js"))
      expect(page).to contain(%(src="/vendor/dataTables.min.js"))
      expect(page).to contain(%(href="/vendor/dataTables.min.css"))
    end

    it "answers 404 to a path that is not one of its assets" do
      ["/favicon.ico", "/admin.jss", "/vendor/other.js"].each do |path|
        ctx = make_ctx("GET", path)
        server.handle(ctx)
        expect(ctx.response.status_code).to eq(404)
      end
    end

    it "serves the page shell on /index.html too" do
      ctx = make_ctx("GET", "/index.html")
      server.handle(ctx)
      expect(ctx.response.status_code).to eq(200)
      expect(ctx.response.headers["Content-Type"]).to eq("text/html")
    end
  end
end
