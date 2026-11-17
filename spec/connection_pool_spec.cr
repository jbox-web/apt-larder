require "./spec_helper"

Spectator.describe AptLarder::ConnectionPool do
  subject(pool) { AptLarder::ConnectionPool.new }

  let(uri) { URI.parse("http://example.com") }
  let(uri_port) { URI.parse("http://example.com:8080") }
  let(uri_other) { URI.parse("http://other.com") }

  # An IO whose `close` always fails with something other than an `IO::Error`
  # (which `HTTP::Client#close` swallows on its own), as a TLS socket does
  # when its shutdown fails.
  private class UnclosableIO < IO::Memory
    def close : Nil
      raise "close failed"
    end
  end

  # `HTTP::Client` exposes no `closed?`. A client built over an IO of ours
  # closes that IO when it is closed itself, and the IO can be asked.
  private def client_over(io : IO) : HTTP::Client
    HTTP::Client.new(io, "example.com", 80)
  end

  describe "#checkout" do
    it "returns an HTTP::Client when the pool is empty" do
      expect(pool.checkout(uri)).to be_a(HTTP::Client)
    end
  end

  describe "#checkin and #checkout" do
    it "returns the same client that was checked in" do
      client = HTTP::Client.new(uri)
      pool.checkin(uri, client)
      expect(pool.checkout(uri).object_id).to eq(client.object_id)
    end

    it "does not mix clients from different hosts" do
      client = HTTP::Client.new(uri)
      pool.checkin(uri, client)
      other = pool.checkout(uri_other)
      expect(other.object_id).not_to eq(client.object_id)
    end

    it "keeps pools separate for different ports on the same host" do
      client_80 = HTTP::Client.new(uri)
      client_8080 = HTTP::Client.new(uri_port)
      pool.checkin(uri, client_80)
      pool.checkin(uri_port, client_8080)
      expect(pool.checkout(uri).object_id).to eq(client_80.object_id)
      expect(pool.checkout(uri_port).object_id).to eq(client_8080.object_id)
    end

    it "returns a fresh client once the pool is drained" do
      client = HTTP::Client.new(uri)
      pool.checkin(uri, client)
      pool.checkout(uri)
      fresh = pool.checkout(uri)
      expect(fresh.object_id).not_to eq(client.object_id)
    end

    it "caps idle connections at IDLE_PER_HOST" do
      limit = AptLarder::ConnectionPool::IDLE_PER_HOST
      clients = Array(HTTP::Client).new(limit + 1) { HTTP::Client.new(uri) }
      clients.each { |client| pool.checkin(uri, client) }

      # Drain: pool holds exactly limit clients (the first `limit` checked in)
      kept_ids = limit.times.map { pool.checkout(uri).object_id }.to_a
      expect(kept_ids.to_set).to eq(clients[0, limit].map(&.object_id).to_set)

      # Pool is now empty — next checkout allocates a fresh client
      fresh = pool.checkout(uri)
      expect(clients.map(&.object_id).includes?(fresh.object_id)).to be_false
    end

    it "closes the connection checked in beyond IDLE_PER_HOST and leaves the pooled ones open" do
      ios = Array(IO::Memory).new(5) { IO::Memory.new }
      ios.each { |io| pool.checkin(uri, client_over(io)) }

      expect(ios.map(&.closed?)).to eq([false, false, false, false, true])
    end
  end

  describe "idle expiry" do
    it "discards a connection idle longer than IDLE_TTL and returns a fresh one" do
      t0 = Time.instant
      client = HTTP::Client.new(uri)
      pool.checkin(uri, client, now: t0)
      later = t0 + AptLarder::ConnectionPool::IDLE_TTL + 1.second
      expect(pool.checkout(uri, now: later).object_id).not_to eq(client.object_id)
    end

    it "closes a connection idle longer than IDLE_TTL when it is skipped at checkout" do
      t0 = Time.instant
      expired = IO::Memory.new
      pool.checkin(uri, client_over(expired), now: t0)
      pool.checkout?(uri, now: t0 + 51.seconds)
      expect(expired.closed?).to be_true
    end

    it "leaves a connection still within IDLE_TTL open at checkout" do
      t0 = Time.instant
      kept = IO::Memory.new
      pool.checkin(uri, client_over(kept), now: t0)
      pool.checkout?(uri, now: t0 + 49.seconds)
      expect(kept.closed?).to be_false
    end

    it "reuses a connection still within IDLE_TTL" do
      t0 = Time.instant
      client = HTTP::Client.new(uri)
      pool.checkin(uri, client, now: t0)
      within = t0 + AptLarder::ConnectionPool::IDLE_TTL - 1.second
      expect(pool.checkout(uri, now: within).object_id).to eq(client.object_id)
    end

    it "drops the host bucket once drained" do
      client = HTTP::Client.new(uri)
      pool.checkin(uri, client)
      pool.checkout(uri)
      expect(pool.@idle.empty?).to be_true
    end
  end

  describe "#discard" do
    it "closes the connection" do
      io = IO::Memory.new
      pool.discard(client_over(io))
      expect(io.closed?).to be_true
    end

    # Discarding is what the proxy does with a connection it already knows is
    # broken: a failing close must not replace the error being handled.
    it "swallows an error raised while closing" do
      io = UnclosableIO.new
      outcome = begin
        pool.discard(client_over(io))
        "returned"
      rescue ex
        "raised #{ex.message}"
      end
      expect(outcome).to eq("returned")
    end
  end

  describe "#checkout?" do
    it "returns nil when no connection is pooled for the host" do
      expect(pool.checkout?(uri)).to be_nil
    end

    it "returns the pooled connection" do
      client = HTTP::Client.new(uri)
      pool.checkin(uri, client)
      expect(pool.checkout?(uri).try(&.object_id)).to eq(client.object_id)
    end
  end

  describe "#sweep" do
    it "closes the idle connections of every host once they are too old" do
      now = Time.instant
      pool.checkin(uri, HTTP::Client.new(uri), now - 2.minutes)
      pool.checkin(uri_other, HTTP::Client.new(uri_other), now - 2.minutes)
      expect(pool.sweep(now)).to eq(2)
      expect(pool.idle_count).to eq(0)
    end

    it "closes the expired connections and leaves the fresh ones open" do
      now = Time.instant
      old_io = IO::Memory.new
      fresh_io = IO::Memory.new
      pool.checkin(uri, client_over(old_io), now - 2.minutes)
      pool.checkin(uri_other, client_over(fresh_io), now - 5.seconds)
      pool.sweep(now)
      expect(old_io.closed?).to be_true
      expect(fresh_io.closed?).to be_false
    end

    it "keeps the connections that are still fresh" do
      now = Time.instant
      old = HTTP::Client.new(uri)
      fresh = HTTP::Client.new(uri)
      pool.checkin(uri, old, now - 2.minutes)
      pool.checkin(uri, fresh, now - 5.seconds)
      expect(pool.sweep(now)).to eq(1)
      expect(pool.idle_count).to eq(1)
      expect(pool.checkout?(uri, now).try(&.object_id)).to eq(fresh.object_id)
    end
  end
end
