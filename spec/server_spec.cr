require "./spec_helper"
require "file_utils"

Spectator.describe AptLarder::Server do
  let(tmp_dir) { spec_tmp_dir("server") }

  after_each { FileUtils.rm_rf(tmp_dir) }

  # A configuration listening on loopback, on ports the kernel picks.
  private def config(extra : String = "") : AptLarder::Config
    AptLarder::Config.from_yaml(<<-YAML)
      cache_dir: #{tmp_dir}
      server_host: "127.0.0.1"
      server_port: 0
      #{extra}
      YAML
  end

  # Runs *server* in a fiber, yields once it listens, then stops it and
  # returns whether `start` came back.
  private def running(server : AptLarder::Server, &) : Bool
    returned = Channel(Nil).new(1)
    spawn do
      server.start
      returned.send(nil)
    end
    deadline = Time.instant + 5.seconds
    until server.address || Time.instant > deadline
      sleep 5.milliseconds
    end
    begin
      yield
    ensure
      server.stop
    end
    select
    when returned.receive
      true
    when timeout(5.seconds)
      false
    end
  end

  private def port_of(server : AptLarder::Server) : Int32
    server.address.try(&.port) || raise "server is not listening"
  end

  it "serves the liveness probe, and start returns once stopped" do
    server = AptLarder::Server.new(config)
    status = 0
    returned = running(server) do
      status = HTTP::Client.get("http://127.0.0.1:#{port_of(server)}/_health").status_code
    end
    expect(status).to eq(200)
    expect(returned).to be_true
  end

  it "runs eviction at startup, not an hour later" do
    stale = File.join(tmp_dir, "mirror/pool/old.deb")
    recent = File.join(tmp_dir, "mirror/pool/recent.deb")
    Dir.mkdir_p(File.dirname(stale))
    File.write(stale, "old")
    File.write(recent, "recent")
    past = Time.utc - 10.days
    File.utime(past, past, stale)

    server = AptLarder::Server.new(config("evict_after_days: 1"))
    running(server) do
      deadline = Time.instant + 5.seconds
      while File.exists?(stale) && Time.instant < deadline
        sleep 10.milliseconds
      end
    end
    expect(File.exists?(stale)).to be_false
    expect(File.exists?(recent)).to be_true
  end

  context "with the admin server enabled" do
    it "serves the admin API on its own port" do
      server = AptLarder::Server.new(config("admin:\n  enabled: true\n  port: 0"))
      status = 0
      running(server) do
        admin_port = server.admin_address.try(&.port) || raise "admin server is not listening"
        status = HTTP::Client.get("http://127.0.0.1:#{admin_port}/api/health").status_code
      end
      expect(status).to eq(200)
    end

    # The admin server used to bind in a fiber of its own: a port already in
    # use left the proxy running, announced as ready, with no admin and no
    # metrics.
    it "fails to start when the admin port cannot be bound" do
      occupied = TCPServer.new("127.0.0.1", 0)
      begin
        server = AptLarder::Server.new(config("admin:\n  enabled: true\n  port: #{occupied.local_address.port}"))
        expect { server.start }.to raise_error(Socket::BindError)
        expect(server.address).to be_nil
      ensure
        occupied.close
      end
    end
  end
end
