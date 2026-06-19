require "./spec_helper"
require "file_utils"
require "digest/sha256"

Spectator.describe AptLarder::Cache do
  let(tmp_dir) { "/tmp/apt-larder-cache-#{Random::Secure.hex(4)}" }
  subject(cache) { AptLarder::Cache.new(tmp_dir) }

  after_each { FileUtils.rm_rf(tmp_dir) }

  private def store(key : String, content : String) : Nil
    cache.store(key, IO::Memory.new(content.to_slice))
  end

  describe "#exists?" do
    it "returns false for unknown key" do
      expect(cache.exists?("pkg.deb")).to be_false
    end

    it "returns true after store" do
      store("pkg.deb", "data")
      expect(cache.exists?("pkg.deb")).to be_true
    end
  end

  describe "#store" do
    it "handles a zero-byte body" do
      store("empty.deb", "")
      expect(cache.exists?("empty.deb")).to be_true
      expect(cache.size("empty.deb")).to eq(0_i64)
    end

    it "writes the content" do
      store("pkg/hello.deb", "hello world")
      file = cache.open("pkg/hello.deb")
      content = file.gets_to_end
      file.close
      expect(content).to eq("hello world")
    end

    it "creates intermediate directories" do
      store("a/b/c/pkg.deb", "x")
      expect(cache.exists?("a/b/c/pkg.deb")).to be_true
    end

    it "overwrites an existing entry" do
      store("pkg.deb", "v1")
      store("pkg.deb", "v2")
      file = cache.open("pkg.deb")
      content = file.gets_to_end
      file.close
      expect(content).to eq("v2")
    end

    it "removes the .tmp file on failure" do
      broken = IO::Memory.new
      broken.close # lecture depuis un IO fermé lève IO::Error
      expect { cache.store("pkg.deb", broken) }.to raise_error
      tmps = Dir.glob("#{tmp_dir}/**/*.tmp")
      expect(tmps).to be_empty
    end
  end

  describe "#fresh?" do
    it "returns false for unknown key" do
      expect(cache.fresh?("missing.deb", 5.minutes)).to be_false
    end

    it "returns true for a recently stored file" do
      store("pkg.deb", "data")
      expect(cache.fresh?("pkg.deb", 5.minutes)).to be_true
    end

    it "returns false when TTL is zero" do
      store("pkg.deb", "data")
      expect(cache.fresh?("pkg.deb", 0.seconds)).to be_false
    end
  end

  describe "#modification_time?" do
    it "returns nil for unknown key" do
      expect(cache.modification_time?("missing.deb")).to be_nil
    end

    it "returns a Time for an existing file" do
      store("pkg.deb", "data")
      expect(cache.modification_time?("pkg.deb")).not_to be_nil
    end
  end

  describe "#touch" do
    it "updates the mtime" do
      store("pkg.deb", "data")
      before = cache.modification_time?("pkg.deb") || raise "expected mtime"
      sleep 10.milliseconds
      cache.touch("pkg.deb")
      after = cache.modification_time?("pkg.deb") || raise "expected mtime"
      expect(after).to be >= before
    end

    it "does not raise when file does not exist" do
      expect { cache.touch("missing.deb") }.not_to raise_error
    end
  end

  describe "#size" do
    it "returns the correct byte size" do
      store("pkg.deb", "hello")
      expect(cache.size("pkg.deb")).to eq(5_i64)
    end
  end

  describe "#store (integrity)" do
    it "creates a .sha256 sidecar" do
      store("pkg.deb", "hello")
      expect(File.exists?(File.join(tmp_dir, "pkg.deb.sha256"))).to be_true
    end
  end

  # Writes a file+sidecar directly to disk, bypassing store() and @verified,
  # so that valid?() actually exercises the SHA256 verification path.
  private def plant(key : String, content : String) : Nil
    path = File.join(tmp_dir, key)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.write("#{path}.sha256", Digest::SHA256.hexdigest(content))
  end

  describe "#valid?" do
    it "returns true for a correctly stored file" do
      store("pkg.deb", "hello")
      expect(cache.valid?("pkg.deb")).to be_true
    end

    it "returns false for a file with a mismatched sidecar" do
      plant("pkg.deb", "hello")
      File.write(File.join(tmp_dir, "pkg.deb.sha256"), "deadbeef")
      expect(cache.valid?("pkg.deb")).to be_false
    end

    it "returns true for a file without a sidecar (pre-integrity files)" do
      path = File.join(tmp_dir, "pkg.deb")
      Dir.mkdir_p(File.dirname(path))
      File.write(path, "hello")
      expect(cache.valid?("pkg.deb")).to be_true
    end

    it "caches the verified result — second call skips SHA256" do
      plant("pkg.deb", "hello")
      cache.valid?("pkg.deb")
      # corrupt the sidecar — second call must return true from @verified
      File.write(File.join(tmp_dir, "pkg.deb.sha256"), "deadbeef")
      expect(cache.valid?("pkg.deb")).to be_true
    end

    # The hot path calls valid? outside any File::Error rescue, so a file that
    # vanishes mid-check (concurrent eviction) must degrade to false, not raise.
    it "returns false instead of raising when the file disappears mid-check" do
      plant("pkg.deb", "hello")
      # data file gone but sidecar remains — sha256_of would raise File::Error
      File.delete(File.join(tmp_dir, "pkg.deb"))
      expect(cache.valid?("pkg.deb")).to be_false
    end
  end

  describe "#verified?" do
    it "is false before verification and true after a successful valid?" do
      plant("pkg.deb", "hello")
      expect(cache.verified?("pkg.deb")).to be_false
      cache.valid?("pkg.deb")
      expect(cache.verified?("pkg.deb")).to be_true
    end

    it "stays false after a failed valid? (corrupt file)" do
      plant("pkg.deb", "hello")
      File.write(File.join(tmp_dir, "pkg.deb.sha256"), "deadbeef")
      expect(cache.valid?("pkg.deb")).to be_false
      expect(cache.verified?("pkg.deb")).to be_false
    end
  end

  describe "#invalidate" do
    it "removes the file and its sidecar" do
      store("pkg.deb", "hello")
      cache.invalidate("pkg.deb")
      expect(cache.exists?("pkg.deb")).to be_false
      expect(File.exists?(File.join(tmp_dir, "pkg.deb.sha256"))).to be_false
    end

    it "is a no-op for a key containing .. (never deletes outside the root)" do
      # victim sits in the parent of the cache root; "../victim.txt" resolves to it
      victim = File.join(File.dirname(tmp_dir), "victim-#{Random::Secure.hex(4)}.txt")
      File.write(victim, "keep me")
      begin
        cache.invalidate("../#{File.basename(victim)}")
        expect(File.exists?(victim)).to be_true
      ensure
        File.delete(victim) if File.exists?(victim)
      end
    end

    it "removes the key from all memory caches" do
      store("pkg.deb", "hello")
      cache.valid?("pkg.deb")
      cache.invalidate("pkg.deb")
      expect(cache.fresh?("pkg.deb", 5.minutes)).to be_false
    end
  end

  describe "#clear" do
    it "deletes all files and sidecars and returns the count" do
      store("a/pkg.deb", "x")
      store("b/other.deb", "yy")
      deleted = cache.clear
      expect(deleted).to eq(2)
      expect(cache.exists?("a/pkg.deb")).to be_false
      expect(cache.exists?("b/other.deb")).to be_false
      expect(File.exists?(File.join(tmp_dir, "a/pkg.deb.sha256"))).to be_false
      expect(cache.entry_count).to eq(0)
    end

    it "returns zero on an empty cache" do
      expect(cache.clear).to eq(0)
    end
  end

  describe "#evict_stale" do
    it "returns zero counts when the cache is empty" do
      deleted, freed = cache.evict_stale(7.days)
      expect(deleted).to eq(0)
      expect(freed).to eq(0_i64)
    end

    it "removes files older than max_age and returns counts" do
      store("old.deb", "data")
      old_path = File.join(tmp_dir, "old.deb")
      past = Time.utc - 8.days
      File.utime(past, past, old_path)
      store("fresh.deb", "data")

      deleted, freed = cache.evict_stale(7.days)

      expect(deleted).to eq(1)
      expect(freed).to be > 0_i64
      expect(cache.exists?("old.deb")).to be_false
      expect(cache.exists?("fresh.deb")).to be_true
    end

    it "returns zero when nothing is stale" do
      store("fresh.deb", "data")
      deleted, _ = cache.evict_stale(7.days)
      expect(deleted).to eq(0)
    end

    it "also removes .sha256 sidecars for evicted files" do
      store("old.deb", "data")
      old_path = File.join(tmp_dir, "old.deb")
      past = Time.utc - 8.days
      File.utime(past, past, old_path)

      cache.evict_stale(7.days)

      expect(File.exists?("#{old_path}.sha256")).to be_false
    end
  end

  describe "#entry_count" do
    it "returns 0 for an empty cache" do
      expect(cache.entry_count).to eq(0)
    end

    it "returns the number of stored files" do
      store("a.deb", "x")
      store("b.deb", "y")
      expect(cache.entry_count).to eq(2)
    end
  end

  describe "#evict (combined)" do
    it "applies both time-based and size-based eviction in one scan" do
      store("stale.deb", "aaaaa")
      stale_path = File.join(tmp_dir, "stale.deb")
      File.utime(Time.utc - 10.days, Time.utc - 10.days, stale_path)

      store("old.deb", "bbb")
      old_path = File.join(tmp_dir, "old.deb")
      File.utime(Time.utc - 2.days, Time.utc - 2.days, old_path)

      store("fresh.deb", "cc")

      # stale.deb removed by time pass (>7 days)
      # old.deb removed by size pass (total after time pass = 5 bytes > limit 3)
      deleted, _ = cache.evict(max_age: 7.days, limit_bytes: 3)
      expect(deleted).to eq(2)
      expect(cache.exists?("stale.deb")).to be_false
      expect(cache.exists?("old.deb")).to be_false
      expect(cache.exists?("fresh.deb")).to be_true
    end
  end

  describe "#evict_to_limit" do
    it "returns zero when already under the limit" do
      store("pkg.deb", "hello")
      deleted, freed = cache.evict_to_limit(1_000_000)
      expect(deleted).to eq(0)
      expect(freed).to eq(0_i64)
    end

    it "evicts oldest files first until under the limit" do
      store("old.deb", "aaaaa")
      old_path = File.join(tmp_dir, "old.deb")
      past = Time.utc - 2.days
      File.utime(past, past, old_path)

      store("new.deb", "bb")

      # limit = 3 bytes; total = 7; must evict old.deb (5 bytes)
      deleted, freed = cache.evict_to_limit(3)
      expect(deleted).to eq(1)
      expect(freed).to eq(5_i64)
      expect(cache.exists?("old.deb")).to be_false
      expect(cache.exists?("new.deb")).to be_true
    end
  end

  describe "#entries" do
    it "returns all cached files with metadata" do
      store("a/pkg.deb", "hello")
      store("b/index", "world")
      result = cache.entries
      expect(result[:total]).to eq(2)
      expect(result[:entries].map(&.key).sort!).to eq(["a/pkg.deb", "b/index"])
    end

    it "filters by prefix" do
      store("deb.debian.org/pool/pkg.deb", "x")
      store("security.debian.org/pool/pkg2.deb", "y")
      result = cache.entries(prefix: "deb.debian.org")
      expect(result[:total]).to eq(1)
      expect(result[:entries].first.key).to eq("deb.debian.org/pool/pkg.deb")
    end

    it "paginates results" do
      5.times { |i| store("mirror/pool/pkg#{i}.deb", "data") }
      result = cache.entries(page: 2, per_page: 2)
      expect(result[:entries].size).to eq(2)
      expect(result[:total]).to eq(5)
    end

    it "excludes .sha256 sidecars" do
      store("pkg.deb", "data")
      result = cache.entries
      expect(result[:entries].none?(&.key.ends_with?(".sha256"))).to be_true
    end

    it "sets immutable flag for .deb files" do
      store("pool/main/pkg.deb", "data")
      store("dists/stable/Release", "data")
      result = cache.entries
      deb = result[:entries].find!(&.key.ends_with?(".deb"))
      idx = result[:entries].find!(&.key.ends_with?("Release"))
      expect(deb.immutable?).to be_true
      expect(idx.immutable?).to be_false
    end
  end
end
