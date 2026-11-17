require "./spec_helper"
require "file_utils"

Spectator.describe AptLarder::SystemD do
  # Resets the persistent socket between examples so each test gets a clean
  # state. Done before as well as after: Spectator skips `after_each` when an
  # example fails, and the socket left behind would fail the next one too.
  before_each { AptLarder::SystemD.reset_socket }
  after_each { AptLarder::SystemD.reset_socket }

  # How long an example waits for a datagram before failing. A notification
  # that never arrives must fail its example, not hang the suite.
  RECEIVE_TIMEOUT = 1.second

  private def with_notify_socket(& : String, Socket -> T) : T forall T
    dir = spec_tmp_dir("sd")
    Dir.mkdir_p(dir)
    path = File.join(dir, "notify.sock")
    server = Socket.new(Socket::Family::UNIX, Socket::Type::DGRAM)
    server.read_timeout = RECEIVE_TIMEOUT
    begin
      server.bind(Socket::UNIXAddress.new(path))
      with_env({"NOTIFY_SOCKET" => path}) { yield path, server }
    ensure
      server.close rescue nil
      FileUtils.rm_rf(dir)
    end
  end

  # Runs the block with *key* removed from the environment, then restores it.
  # `with_env` can only set a variable; these examples need one to be absent.
  private def without_env(key : String, &)
    previous = ENV[key]?
    ENV.delete(key)
    begin
      yield
    ensure
      ENV[key] = previous if previous
    end
  end

  # Next datagram received by *server*; raises `IO::TimeoutError` after
  # `RECEIVE_TIMEOUT` when none arrives.
  private def next_message(server : Socket) : String
    message, _ = server.receive(256)
    message
  end

  it "sends READY=1 to the notify socket" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.ready
      expect(next_message(server)).to eq("READY=1")
    end
  end

  it "sends STOPPING=1" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.stopping
      expect(next_message(server)).to eq("STOPPING=1")
    end
  end

  it "sends WATCHDOG=1" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.watchdog
      expect(next_message(server)).to eq("WATCHDOG=1")
    end
  end

  it "sends STATUS with the message" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.status("1234 hits (95.0%), 67 misses, 1.2 GB served")
      expect(next_message(server)).to eq("STATUS=1234 hits (95.0%), 67 misses, 1.2 GB served")
    end
  end

  it "reuses the same socket across calls" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.ready
      AptLarder::SystemD.watchdog
      expect(next_message(server)).to eq("READY=1")
      expect(next_message(server)).to eq("WATCHDOG=1")
    end
  end

  # Datagrams on a UNIX socket are delivered in order: had the notification
  # issued while the variable was unset gone out on the socket already open,
  # it would be read before STOPPING=1.
  it "sends nothing while NOTIFY_SOCKET is unset, even with a socket already open" do
    with_notify_socket do |_, server|
      AptLarder::SystemD.ready
      expect(next_message(server)).to eq("READY=1")
      without_env("NOTIFY_SOCKET") { AptLarder::SystemD.watchdog }
      AptLarder::SystemD.stopping
      expect(next_message(server)).to eq("STOPPING=1")
    end
  end

  # The persistent socket is connected to one listener. Once that listener is
  # gone a send fails; the failure must drop the socket so the next
  # notification connects again instead of failing forever.
  it "re-opens the socket after a failed send" do
    with_notify_socket do |first_path, first|
      AptLarder::SystemD.ready
      expect(next_message(first)).to eq("READY=1")

      first.close
      File.delete(first_path)
      # Fails on the dead listener; best-effort, so nothing is raised.
      AptLarder::SystemD.watchdog

      with_notify_socket do |_, second|
        AptLarder::SystemD.stopping
        expect(next_message(second)).to eq("STOPPING=1")
      end
    end
  end

  # `start_watchdog` has no stop: its fiber keeps ticking until the process
  # exits, and notifies whatever socket NOTIFY_SOCKET names at that moment.
  # The interval is kept long (200 ms) so that a later tick has next to no
  # chance of landing inside the few microseconds another example spends
  # between setting NOTIFY_SOCKET and reading its datagram.
  it "sends WATCHDOG=1 from the watchdog fiber at half of WATCHDOG_USEC" do
    with_notify_socket do |_, server|
      with_env({"WATCHDOG_USEC" => "400000"}) { AptLarder::SystemD.start_watchdog }
      expect(next_message(server)).to eq("WATCHDOG=1")
    end
  end

  it "returns watchdog_interval as half of WATCHDOG_USEC" do
    interval = with_env({"WATCHDOG_USEC" => "60000000"}) { AptLarder::SystemD.watchdog_interval }
    expect(interval).to eq(30.seconds)
  end

  it "returns nil watchdog_interval when WATCHDOG_USEC is not set" do
    interval = without_env("WATCHDOG_USEC") { AptLarder::SystemD.watchdog_interval }
    expect(interval).to be_nil
  end
end
