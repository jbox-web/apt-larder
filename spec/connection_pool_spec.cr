require "./spec_helper"

Spectator.describe AptLarder::ConnectionPool do
  subject(pool) { AptLarder::ConnectionPool.new }

  let(uri) { URI.parse("http://example.com") }
  let(uri_port) { URI.parse("http://example.com:8080") }
  let(uri_other) { URI.parse("http://other.com") }

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
  end

  describe "idle expiry" do
    it "discards a connection idle longer than IDLE_TTL and returns a fresh one" do
      t0 = Time.monotonic
      client = HTTP::Client.new(uri)
      pool.checkin(uri, client, now: t0)
      later = t0 + AptLarder::ConnectionPool::IDLE_TTL + 1.second
      expect(pool.checkout(uri, now: later).object_id).not_to eq(client.object_id)
    end

    it "reuses a connection still within IDLE_TTL" do
      t0 = Time.monotonic
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
    it "does not raise on an open client" do
      expect { pool.discard(HTTP::Client.new(uri)) }.not_to raise_error
    end

    it "does not raise on an already-closed client" do
      client = HTTP::Client.new(uri)
      client.close
      expect { pool.discard(client) }.not_to raise_error
    end
  end
end
