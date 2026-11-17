require "./spec_helper"

# Abstract UNIX sockets (a name starting with "@" in NOTIFY_SOCKET) only exist
# on Linux, so this file compiles to nothing elsewhere. Run it in a Linux
# container when working from macOS.
{% if flag?(:linux) %}
  Spectator.describe "AptLarder::SystemD with an abstract notify socket" do
    after_each { AptLarder::SystemD.reset_socket }

    # Binds a datagram socket to the abstract *name*, the way systemd does:
    # the address length covers the name exactly, with no padding.
    private def abstract_server(name : String) : Socket
      server = Socket.new(Socket::Family::UNIX, Socket::Type::DGRAM)
      addr = LibC::SockaddrUn.new
      addr.sun_family = LibC::AF_UNIX.to_u16
      offset = offsetof(LibC::SockaddrUn, @sun_path)
      (pointerof(addr).as(UInt8*) + offset + 1).copy_from(name.to_unsafe, name.bytesize)
      length = LibC::SocklenT.new(offset + 1 + name.bytesize)
      unless LibC.bind(server.fd, pointerof(addr).as(LibC::Sockaddr*), length) == 0
        raise Socket::BindError.from_errno("bind")
      end
      server.read_timeout = 1.second
      server
    end

    it "delivers READY=1 to a socket named with a leading @" do
      name = "apt-larder-spec-#{Process.pid}-#{Random::Secure.hex(4)}"
      server = abstract_server(name)
      begin
        with_env({"NOTIFY_SOCKET" => "@#{name}"}) do
          AptLarder::SystemD.ready
          buf = Bytes.new(64)
          n = server.read(buf)
          expect(String.new(buf[0, n])).to eq("READY=1")
        end
      ensure
        server.close
      end
    end
  end
{% end %}
