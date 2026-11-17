module AptLarder
  # Log backend for the access and application log: a file opened in append
  # mode, or standard output.
  #
  # Two properties the stock `Log::IOBackend` does not have, and that a
  # long-running proxy needs:
  #
  # - **It writes synchronously.** The default asynchronous dispatcher hands
  #   entries to a writer fiber through a bounded channel. One failed write
  #   kills that fiber for good; 2048 entries later the channel is full and
  #   every fiber that logs blocks forever — each request hangs after its
  #   body, while the watchdog fiber keeps telling systemd all is well.
  # - **A failed write never reaches the caller.** A full log partition or a
  #   closed stdout pipe is reported once on a fallback stream (standard
  #   error), and the entries are dropped until the destination works again.
  class LogBackend < ::Log::IOBackend
    # *fallback* receives the one-line notices about the log itself failing.
    def initialize(io : IO, @fallback : IO = STDERR)
      super(io, dispatcher: ::Log::DispatchMode::Sync)
      @failing = false
    end

    # Writes *entry*; on failure, reports once and drops it.
    def write(entry : ::Log::Entry) : Nil
      super
      @failing = false
    rescue ex : IO::Error
      report("cannot write to the log: #{ex.message}") unless @failing
      @failing = true
    end

    # Points the backend at the file at *path*, opened in append mode — what
    # log rotation needs once the previous file has been renamed away.
    #
    # The new file is opened before the current one is let go: when it cannot
    # be opened (missing directory, permissions), the backend keeps writing
    # where it was and `false` is returned.
    def reopen(path : String) : Bool
      fresh = File.open(path, "a")
      previous = io
      self.io = fresh
      close_stream(previous)
      true
    rescue ex : IO::Error
      report("cannot reopen the log file: #{ex.message}")
      false
    end

    # Closes the destination, unless it is a standard stream.
    def close_io : Nil
      close_stream(io)
    end

    private def close_stream(stream : IO) : Nil
      return if stream.same?(STDOUT) || stream.same?(STDERR)
      stream.close
    rescue IO::Error
    end

    private def report(message : String) : Nil
      @fallback.puts "apt-larder: #{message}"
      @fallback.flush
    rescue IO::Error
    end
  end
end
