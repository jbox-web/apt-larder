module AptLarder
  # Deduplicates concurrent fetches for the same cache key.
  #
  # The first fiber to call `run` for a given key becomes the *leader* and
  # executes the block. Every subsequent fiber that calls `run` for the same
  # key while the leader is still running becomes a *waiter* and blocks on a
  # channel until the leader finishes.
  #
  # When the leader's block returns (or raises), the channel is closed, waking
  # all waiters at once (broadcast semantics — a send would only wake one).
  # The exception, if any, propagates only in the leader fiber; waiters return
  # normally regardless of whether the leader succeeded or failed.
  #
  # The same key can be reused immediately after a run completes.
  class SingleFlight
    # One run in progress: the channel its waiters block on, and how many
    # callers joined it.
    private class Flight
      getter channel = Channel(Nil).new
      property waiters = 0
    end

    def initialize
      @mutex = Mutex.new
      @inflight = {} of String => Flight
    end

    # Runs *block* for *key*, or waits for the in-flight run to finish.
    #
    # Only one block executes per key at a time. If a fiber is already running
    # a block for *key*, this fiber blocks until that block finishes, then
    # returns without running the block again.
    def run(key : String, &) : Nil
      flight, leader = @mutex.synchronize do
        if existing = @inflight[key]?
          existing.waiters += 1
          {existing, false}
        else
          created = Flight.new
          @inflight[key] = created
          {created, true}
        end
      end

      if leader
        begin
          yield
        ensure
          # Delete first so a new request arriving immediately after close
          # gets a fresh entry rather than the closing channel.
          @mutex.synchronize { @inflight.delete(key) }
          flight.channel.close
        end
      else
        # blocks until the leader closes the channel
        flight.channel.receive?
      end
    end

    # Number of callers that joined the run in progress for *key* as waiters
    # (0 when there is none). A caller is counted as soon as it has found the
    # run, under the same lock the leader removes it with: from then on it
    # will not run its own block, even if it has not started blocking yet.
    def waiters(key : String) : Int32
      @mutex.synchronize { @inflight[key]?.try(&.waiters) || 0 }
    end
  end
end
