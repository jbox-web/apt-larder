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
  # ExecStart=/usr/bin/apt-larder server --config /etc/apt-larder.yml
  # ```
  module SystemD
    Log = ::Log.for("apt-larder.systemd")
    @@socket : UNIXSocket? = nil
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
      # On any error (broken socket, etc.) discard it so the next call
      # re-opens a fresh one. Notify is best-effort and must never crash.
      @@mutex.synchronize { @@socket = nil }
    end

    private def self.open_socket(path : String) : UNIXSocket
      # Abstract sockets start with '@'; UNIXSocket expects '\0' instead.
      path = "\0" + path[1..] if path.starts_with?("@")
      UNIXSocket.new(path, type: Socket::Type::DGRAM)
    end
  end
end
