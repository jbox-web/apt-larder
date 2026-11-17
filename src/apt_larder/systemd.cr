module AptLarder
  # Thin wrapper around the systemd sd_notify(3) protocol.
  #
  # Sends newline-delimited state strings to the socket named by
  # `$NOTIFY_SOCKET`. All methods are no-ops when the variable is unset
  # (i.e. when not managed by systemd).
  #
  # A single `UNIXSocket` is opened on first use and reused for all
  # subsequent notifications, avoiding repeated open/close syscalls on
  # the watchdog keepalive path.
  #
  # ## Service file
  #
  # ```ini
  # [Service]
  # Type=notify
  # NotifyAccess=main
  # WatchdogSec=30
  # ExecStart=/usr/local/bin/apt-larder server --config /etc/apt-larder/apt-larder.yml
  # ```
  module SystemD
    Log = ::Log.for("apt-larder.systemd")
    @@socket : Socket? = nil
    @@mutex = Mutex.new

    # Sends `READY=1` — signals that the service is fully started and
    # accepting connections.
    def self.ready : Nil
      notify("READY=1")
    end

    # Sends `STOPPING=1` — signals that the service has received a shutdown
    # request and is draining in-flight requests.
    def self.stopping : Nil
      notify("STOPPING=1")
    end

    # Sends `WATCHDOG=1` — resets the watchdog timer.
    # Call at most every `watchdog_usec / 2` microseconds.
    def self.watchdog : Nil
      notify("WATCHDOG=1")
    end

    # Sends `STATUS=<message>` — a human-readable status line shown by
    # `systemctl status`.
    def self.status(message : String) : Nil
      notify("STATUS=#{message}")
    end

    # Returns the watchdog interval from `$WATCHDOG_USEC`, or `nil` if the
    # watchdog is not configured.
    def self.watchdog_interval : Time::Span?
      usec = ENV["WATCHDOG_USEC"]?.try(&.to_i64?)
      return nil unless usec
      (usec / 2).microseconds
    end

    # Spawns a fiber that sends `WATCHDOG=1` at half the watchdog interval.
    # Does nothing when the watchdog is not configured.
    def self.start_watchdog : Nil
      interval = watchdog_interval
      return unless interval

      spawn do
        loop do
          sleep interval
          watchdog
        end
      end
    end

    # Closes and discards the persistent socket. Intended for tests only.
    def self.reset_socket : Nil
      @@mutex.synchronize do
        @@socket.try(&.close) rescue nil
        @@socket = nil
      end
    end

    private def self.notify(payload : String) : Nil
      socket_path = ENV["NOTIFY_SOCKET"]?
      return unless socket_path

      @@mutex.synchronize do
        sock = @@socket ||= open_socket(socket_path)
        sock.send(payload)
      end
    rescue
      # On any error (broken socket, etc.) close and discard it so the next
      # call re-opens a fresh one. Notify is best-effort and must never crash.
      @@mutex.synchronize do
        @@socket.try(&.close) rescue nil
        @@socket = nil
      end
    end

    private def self.open_socket(path : String) : Socket
      return UNIXSocket.new(path, type: Socket::Type::DGRAM) unless path.starts_with?("@")
      connect_abstract(path[1..])
    end

    # Connects a datagram socket to the abstract UNIX socket *name* (what
    # `NOTIFY_SOCKET=@name` designates, Linux only).
    #
    # An abstract address is a NUL byte followed by the name, and — unlike a
    # path — it is compared over the exact length passed to connect(2).
    # `Socket::UNIXAddress` always passes the size of the whole structure, so
    # the kernel would look for the name padded with NULs, find nothing, and
    # the notification would be refused: the address is built by hand here,
    # with its real length.
    private def self.connect_abstract(name : String) : Socket
      addr = LibC::SockaddrUn.new
      addr.sun_family = LibC::SaFamilyT.new(LibC::AF_UNIX)
      offset = offsetof(LibC::SockaddrUn, @sun_path)
      capacity = sizeof(LibC::SockaddrUn) - offset - 1
      raise ArgumentError.new("abstract socket name too long (#{name.bytesize} > #{capacity} bytes)") if name.bytesize > capacity
      (pointerof(addr).as(UInt8*) + offset + 1).copy_from(name.to_unsafe, name.bytesize)
      length = LibC::SocklenT.new(offset + 1 + name.bytesize)

      socket = Socket.new(Socket::Family::UNIX, Socket::Type::DGRAM)
      unless LibC.connect(socket.fd, pointerof(addr).as(LibC::Sockaddr*), length) == 0
        error = Socket::ConnectError.from_errno("connect")
        socket.close
        raise error
      end
      socket
    end
  end
end
