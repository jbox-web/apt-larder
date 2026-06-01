require "./spec_helper"
require "file_utils"

Spectator.describe AptLarder::SystemD do
  # Resets the persistent socket between examples so each test gets a clean state.
  after_each { AptLarder::SystemD.reset_socket }

  private def with_notify_socket(& : String, Socket -> T) : T forall T
    dir = "/tmp/apt-larder-sd-#{Random::Secure.hex(4)}"
    Dir.mkdir_p(dir)
    path = File.join(dir, "notify.sock")
    server = Socket.new(Socket::Family::UNIX, Socket::Type::DGRAM)
    server.bind(Socket::UNIXAddress.new(path))
    ENV["NOTIFY_SOCKET"] = path
    begin
      yield path, server
    ensure
      ENV.delete("NOTIFY_SOCKET")
      server.close rescue nil
      FileUtils.rm_rf(dir)
    end
  end

  it "sends READY=1 to the notify socket" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.ready
      buf = Bytes.new(256)
      n = server.read(buf)
      msg = String.new(buf[0, n])
      expect(msg).to eq("READY=1")
    end
  end

  it "sends STOPPING=1" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.stopping
      buf = Bytes.new(256)
      n = server.read(buf)
      msg = String.new(buf[0, n])
      expect(msg).to eq("STOPPING=1")
    end
  end

  it "sends WATCHDOG=1" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.watchdog
      buf = Bytes.new(256)
      n = server.read(buf)
      msg = String.new(buf[0, n])
      expect(msg).to eq("WATCHDOG=1")
    end
  end

  it "sends STATUS with the message" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.status("1234 hits (95.0%), 67 misses, 1.2 GB served")
      msg, _ = server.receive(256)
      expect(msg).to eq("STATUS=1234 hits (95.0%), 67 misses, 1.2 GB served")
    end
  end

  it "reuses the same socket across calls" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.ready
      AptLarder::SystemD.watchdog
      msg1, _ = server.receive(32)
      msg2, _ = server.receive(32)
      expect(msg1).to eq("READY=1")
      expect(msg2).to eq("WATCHDOG=1")
    end
  end

  it "is a no-op when NOTIFY_SOCKET is not set" do
    ENV.delete("NOTIFY_SOCKET")
    expect { AptLarder::SystemD.ready }.not_to raise_error
  end

  it "returns watchdog_interval as half of WATCHDOG_USEC" do
    ENV["WATCHDOG_USEC"] = "60000000"
    interval = AptLarder::SystemD.watchdog_interval
    ENV.delete("WATCHDOG_USEC")
    expect(interval).to eq(30.seconds)
  end

  it "returns nil watchdog_interval when WATCHDOG_USEC is not set" do
    ENV.delete("WATCHDOG_USEC")
    expect(AptLarder::SystemD.watchdog_interval).to be_nil
  end
end
