require "./spec_helper"
require "file_utils"
require "digest/sha256"

Spectator.describe AptLarder::Cache do
  let(tmp_dir) { spec_tmp_dir("cache") }
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

    # A directory holds entries, it is not one.
    it "returns false for a directory" do
      store("mirror/pool/pkg.deb", "data")
      expect(cache.exists?("mirror/pool")).to be_false
      expect(cache.exists?("mirror")).to be_false
    end
  end

  describe "cache root given with a trailing slash" do
    subject(cache) { AptLarder::Cache.new("#{tmp_dir}/") }

    it "lists entries under their real key" do
      store("mirror/pool/pkg.deb", "data")
      expect(cache.entries[:entries].map(&.key)).to eq(["mirror/pool/pkg.deb"])
    end

    it "really deletes what eviction reports as deleted" do
      store("mirror/pool/pkg.deb", "data")
      past = Time.utc - 10.days
      File.utime(past, past, File.join(tmp_dir, "mirror/pool/pkg.deb"))
      expect(cache.evict(max_age: 1.day)).to eq({1, 4_i64})
      expect(File.exists?(File.join(tmp_dir, "mirror/pool/pkg.deb"))).to be_false
    end
  end

  describe "a key that is both a file and a directory upstream" do
    # A mirror answers 200 (its index page) on a directory path. Cached as a
    # file, it must not keep the packages below it from being stored.
    it "drops the entry standing where a directory is needed" do
      store("mirror/pool/c/curl", "<html>listing</html>")
      store("mirror/pool/c/curl/curl_1.deb", "DEB")
      expect(cache.exists?("mirror/pool/c/curl/curl_1.deb")).to be_true
      expect(File.read(File.join(tmp_dir, "mirror/pool/c/curl/curl_1.deb"))).to eq("DEB")
      expect(cache.exists?("mirror/pool/c/curl")).to be_false
      expect(File.exists?(File.join(tmp_dir, "mirror/pool/c/curl.sha256"))).to be_false
      expect(cache.entry_count).to eq(1)
      expect(cache.total_bytes).to eq(3_i64)
    end

    it "drops a blocking entry several levels up" do
      store("mirror/debian", "<html>listing</html>")
      store("mirror/debian/dists/stable/Release", "release")
      expect(cache.exists?("mirror/debian/dists/stable/Release")).to be_true
      expect(cache.entry_count).to eq(1)
    end

    it "refuses to store onto an existing directory and leaves nothing behind" do
      store("mirror/pool/c/curl/curl_1.deb", "DEB")
      expect { store("mirror/pool/c/curl", "<html>listing</html>") }.to raise_error(File::Error)
      expect(Dir.children(File.join(tmp_dir, "mirror/pool/c")).sort!).to eq(["curl"])
      expect(Dir.children(File.join(tmp_dir, "mirror/pool/c/curl")).sort!).to eq(["curl_1.deb", "curl_1.deb.sha256"])
      expect(cache.entry_count).to eq(1)
    end
  end

  describe "temporary download files" do
    it "recognises the names store gives its temporary files" do
      expect(AptLarder::Cache.temp?("mirror/pkg.deb.0123456789abcdef.tmp")).to be_true
      expect(AptLarder::Cache.temp?("mirror/pkg.deb.tmp")).to be_false
      expect(AptLarder::Cache.temp?("mirror/pkg.deb.0123456789abcdeg.tmp")).to be_false
      expect(AptLarder::Cache.temp?("mirror/pkg.deb")).to be_false
    end

    it "purges the leftovers of a previous run at startup and does not count them" do
      Dir.mkdir_p(File.join(tmp_dir, "mirror"))
      orphan = File.join(tmp_dir, "mirror/pkg.deb.0123456789abcdef.tmp")
      File.write(orphan, "half a download")
      File.write(File.join(tmp_dir, "mirror/pkg.deb"), "data")
      expect(cache.entry_count).to eq(1)
      expect(cache.total_bytes).to eq(4_i64)
      expect(File.exists?(orphan)).to be_false
    end

    # While the server runs, such a file is a download in flight.
    it "is neither listed, flushed nor evicted while a download is in flight" do
      store("mirror/pkg.deb", "data")
      in_flight = File.join(tmp_dir, "mirror/other.deb.0123456789abcdef.tmp")
      File.write(in_flight, "half a download")
      past = Time.utc - 10.days
      File.utime(past, past, in_flight)
      expect(cache.entries[:entries].map(&.key)).to eq(["mirror/pkg.deb"])
      expect(cache.evict(max_age: 1.day)).to eq({0, 0_i64})
      expect(cache.entry_count).to eq(1)
      expect(cache.clear).to eq(1)
      expect(File.exists?(in_flight)).to be_true
    end
  end

  describe "#mark_used" do
    it "brings the mtime of an entry back to now" do
      store("mirror/pool/pkg.deb", "data")
      path = File.join(tmp_dir, "mirror/pool/pkg.deb")
      past = Time.utc - 10.days
      File.utime(past, past, path)
      cache.mark_used("mirror/pool/pkg.deb")
      expect(File.info(path).modification_time).to be > Time.utc - 1.minute
    end

    it "keeps a recently served entry out of time-based eviction" do
      store("mirror/pool/pkg.deb", "data")
      past = Time.utc - 10.days
      File.utime(past, past, File.join(tmp_dir, "mirror/pool/pkg.deb"))
      cache.mark_used("mirror/pool/pkg.deb")
      expect(cache.evict(max_age: 1.day)).to eq({0, 0_i64})
      expect(cache.exists?("mirror/pool/pkg.deb")).to be_true
    end

    it "writes to disk at most once per interval for a given key" do
      store("mirror/pool/pkg.deb", "data")
      path = File.join(tmp_dir, "mirror/pool/pkg.deb")
      cache.mark_used("mirror/pool/pkg.deb")
      past = Time.utc - 10.days
      File.utime(past, past, path)
      cache.mark_used("mirror/pool/pkg.deb")
      expect(File.info(path).modification_time).to be < Time.utc - 9.days
    end

    it "ignores a missing entry" do
      expect { cache.mark_used("mirror/pool/gone.deb") }.not_to raise_error
      expect(cache.exists?("mirror/pool/gone.deb")).to be_false
    end
  end

  describe "deferred disk scan" do
    it "starts with empty gauges and fills them on rescan" do
      store("mirror/pool/pkg.deb", "data")
      deferred = AptLarder::Cache.new(tmp_dir, scan: false)
      expect(deferred.entry_count).to eq(0)
      deferred.rescan
      expect(deferred.entry_count).to eq(1)
      expect(deferred.total_bytes).to eq(4_i64)
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
      # Reading from a closed IO raises IO::Error.
      broken.close
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

    it "returns false once the entry is older than the TTL" do
      store("Release", "data")
      past = Time.utc - 6.minutes
      File.utime(past, past, File.join(tmp_dir, "Release"))
      # A fresh instance: the one that stored the file remembers its own clock.
      reopened = AptLarder::Cache.new(tmp_dir)
      expect(reopened.fresh?("Release", 5.minutes)).to be_false
      expect(reopened.fresh?("Release", 7.minutes)).to be_true
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
      past = Time.utc - 1.hour
      File.utime(past, past, File.join(tmp_dir, "pkg.deb"))
      cache.touch("pkg.deb")
      after = cache.modification_time?("pkg.deb") || raise "expected mtime"
      expect(after).to be > Time.utc - 1.minute
    end

    it "reopens the freshness window of a stale entry" do
      store("Release", "data")
      past = Time.utc - 1.hour
      File.utime(past, past, File.join(tmp_dir, "Release"))
      reopened = AptLarder::Cache.new(tmp_dir)
      expect(reopened.fresh?("Release", 5.minutes)).to be_false
      reopened.touch("Release")
      expect(reopened.fresh?("Release", 5.minutes)).to be_true
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

  describe "upstream validators" do
    let(last_modified) { "Wed, 01 Jan 2020 00:00:00 GMT" }
    let(etag) { %("abc123") }

    private def store_with_validators(key : String) : Nil
      cache.store(key, IO::Memory.new("data".to_slice), last_modified: last_modified, etag: etag)
    end

    it "returns nil for an unknown key" do
      expect(cache.validators("dists/stable/Release")).to be_nil
    end

    it "returns nil for an entry stored without validators" do
      store("dists/stable/Release", "data")
      expect(cache.validators("dists/stable/Release")).to be_nil
    end

    it "returns the Last-Modified and ETag given to store, verbatim" do
      store_with_validators("dists/stable/Release")
      expect(cache.validators("dists/stable/Release")).to eq(
        AptLarder::Cache::Validators.new(last_modified: "Wed, 01 Jan 2020 00:00:00 GMT", etag: %("abc123"))
      )
    end

    it "keeps a single validator when the other is absent" do
      cache.store("dists/stable/Release", IO::Memory.new("data".to_slice), last_modified: last_modified)
      expect(cache.validators("dists/stable/Release")).to eq(
        AptLarder::Cache::Validators.new(last_modified: "Wed, 01 Jan 2020 00:00:00 GMT", etag: nil)
      )
    end

    it "drops stale validators when an entry is re-stored without any" do
      store_with_validators("dists/stable/Release")
      store("dists/stable/Release", "new data")
      expect(cache.validators("dists/stable/Release")).to be_nil
    end

    it "survives touch (a 304 does not change what upstream last sent)" do
      store_with_validators("dists/stable/Release")
      cache.touch("dists/stable/Release")
      expect(cache.validators("dists/stable/Release")).to eq(
        AptLarder::Cache::Validators.new(last_modified: "Wed, 01 Jan 2020 00:00:00 GMT", etag: %("abc123"))
      )
    end

    # The data file is already published when the sidecar is written: a failure
    # there must not turn a good download into an error, nor skip bookkeeping.
    it "still publishes the entry when the validators sidecar cannot be written" do
      # A directory in place of the sidecar makes File.open raise.
      Dir.mkdir_p(File.join(tmp_dir, "dists/stable/Release.validators"))

      expect { store_with_validators("dists/stable/Release") }.not_to raise_error
      expect(cache.entry_count).to eq(1)
      expect(cache.fresh?("dists/stable/Release", 5.minutes)).to be_true
      expect(File.read(File.join(tmp_dir, "dists/stable/Release"))).to eq("data")
    end

    it "is removed by invalidate" do
      store_with_validators("dists/stable/Release")
      cache.invalidate("dists/stable/Release")
      expect(File.exists?(File.join(tmp_dir, "dists/stable/Release.validators"))).to be_false
    end

    it "is removed by clear and not counted as an entry" do
      store_with_validators("dists/stable/Release")
      expect(cache.clear).to eq(1)
      expect(File.exists?(File.join(tmp_dir, "dists/stable/Release.validators"))).to be_false
    end

    it "is removed with its evicted entry and not evicted on its own" do
      store_with_validators("dists/stable/Release")
      path = File.join(tmp_dir, "dists/stable/Release")
      past = Time.utc - 8.days
      File.utime(past, past, path)
      File.utime(past, past, "#{path}.validators")

      deleted, _ = cache.evict_stale(7.days)

      expect(deleted).to eq(1)
      expect(File.exists?("#{path}.validators")).to be_false
    end

    it "is excluded from entries" do
      store_with_validators("dists/stable/Release")
      expect(cache.entries[:entries].map(&.key)).to eq(["dists/stable/Release"])
    end

    it "is not counted by the entry gauge seeded at construction" do
      store_with_validators("dists/stable/Release")
      expect(AptLarder::Cache.new(tmp_dir).entry_count).to eq(1)
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
      Dir.mkdir_p(File.dirname(victim))
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

    it "counts files already on disk at construction" do
      # Pre-populate the directory before the cache is built so the count is
      # seeded from disk, not only from stores made during this session.
      FileUtils.mkdir_p(tmp_dir)
      File.write(File.join(tmp_dir, "preexisting.deb"), "data")
      File.write(File.join(tmp_dir, "preexisting.deb.sha256"), "deadbeef")
      expect(cache.entry_count).to eq(1)
    end

    it "does not double-count when an existing key is re-stored" do
      store("a.deb", "x")
      store("a.deb", "xx")
      expect(cache.entry_count).to eq(1)
    end
  end

  describe "#total_bytes" do
    it "returns 0 for an empty cache" do
      expect(cache.total_bytes).to eq(0_i64)
    end

    it "returns the summed size of the stored files" do
      store("a.deb", "x")
      store("b.deb", "yyy")
      expect(cache.total_bytes).to eq(4_i64)
    end

    it "counts files already on disk at construction, sidecars excluded" do
      FileUtils.mkdir_p(tmp_dir)
      File.write(File.join(tmp_dir, "preexisting.deb"), "data")
      File.write(File.join(tmp_dir, "preexisting.deb.sha256"), "deadbeef")
      expect(cache.total_bytes).to eq(4_i64)
    end

    it "replaces the previous size when an existing key is re-stored" do
      store("a.deb", "x")
      store("a.deb", "xxxxx")
      expect(cache.total_bytes).to eq(5_i64)
    end

    it "subtracts the size of an invalidated entry" do
      store("a.deb", "x")
      store("b.deb", "yyy")
      cache.invalidate("a.deb")
      expect(cache.total_bytes).to eq(3_i64)
    end

    it "is left untouched when invalidating a missing key" do
      store("a.deb", "x")
      cache.invalidate("missing.deb")
      expect(cache.total_bytes).to eq(1_i64)
    end

    it "drops to 0 after a clear" do
      store("a.deb", "x")
      cache.clear
      expect(cache.total_bytes).to eq(0_i64)
    end

    it "is re-anchored to the on-disk size by an eviction pass" do
      store("a.deb", "xx")
      # Written behind the cache's back: only a disk scan can see it.
      File.write(File.join(tmp_dir, "out-of-band.deb"), "12345")
      cache.evict_stale(7.days)
      expect(cache.total_bytes).to eq(7_i64)
    end

    it "subtracts what an eviction pass removes" do
      store("old.deb", "aaaaa")
      past = Time.utc - 8.days
      File.utime(past, past, File.join(tmp_dir, "old.deb"))
      store("fresh.deb", "cc")
      cache.evict_stale(7.days)
      expect(cache.total_bytes).to eq(2_i64)
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

    it "filters by case-insensitive substring" do
      store("deb.debian.org/pool/main/p/php/php-common_1_all.deb", "x")
      store("deb.debian.org/pool/main/c/curl/curl_8_amd64.deb", "y")
      result = cache.entries(search: "PHP-Common")
      expect(result[:total]).to eq(1)
      expect(result[:entries].map(&.key)).to eq(["deb.debian.org/pool/main/p/php/php-common_1_all.deb"])
    end

    it "sorts by key ascending by default" do
      store("c.deb", "x")
      store("a.deb", "x")
      store("b.deb", "x")
      expect(cache.entries[:entries].map(&.key)).to eq(["a.deb", "b.deb", "c.deb"])
    end

    it "sorts by key descending" do
      store("c.deb", "x")
      store("a.deb", "x")
      store("b.deb", "x")
      result = cache.entries(descending: true)
      expect(result[:entries].map(&.key)).to eq(["c.deb", "b.deb", "a.deb"])
    end

    it "sorts by size" do
      store("a.deb", "xx")
      store("b.deb", "xxxxx")
      store("c.deb", "x")
      result = cache.entries(sort: AptLarder::Cache::EntrySort::Size)
      expect(result[:entries].map(&.key)).to eq(["c.deb", "a.deb", "b.deb"])
    end

    it "sorts by modification time" do
      store("a.deb", "x")
      store("b.deb", "x")
      store("c.deb", "x")
      File.utime(Time.utc(2026, 1, 2), Time.utc(2026, 1, 2), File.join(tmp_dir, "a.deb"))
      File.utime(Time.utc(2026, 1, 3), Time.utc(2026, 1, 3), File.join(tmp_dir, "b.deb"))
      File.utime(Time.utc(2026, 1, 1), Time.utc(2026, 1, 1), File.join(tmp_dir, "c.deb"))
      result = cache.entries(sort: AptLarder::Cache::EntrySort::Mtime, descending: true)
      expect(result[:entries].map(&.key)).to eq(["b.deb", "a.deb", "c.deb"])
    end

    it "sorts before paginating" do
      store("a.deb", "xx")
      store("b.deb", "xxxxx")
      store("c.deb", "x")
      result = cache.entries(page: 2, per_page: 2, sort: AptLarder::Cache::EntrySort::Size, descending: true)
      expect(result[:total]).to eq(3)
      expect(result[:entries].map(&.key)).to eq(["c.deb"])
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

    it "returns an empty page far beyond the last one instead of overflowing" do
      store("mirror/pkg.deb", "data")
      result = cache.entries(page: Int32::MAX, per_page: 200)
      expect(result[:entries]).to be_empty
      expect(result[:total]).to eq(1)
    end

    # Listings are served from a short-lived snapshot: a change made through
    # the cache must never be hidden by it.
    it "reflects a store and an invalidate made right after a listing" do
      store("mirror/a.deb", "data")
      expect(cache.entries[:entries].map(&.key)).to eq(["mirror/a.deb"])
      store("mirror/b.deb", "data")
      expect(cache.entries[:entries].map(&.key)).to eq(["mirror/a.deb", "mirror/b.deb"])
      cache.invalidate("mirror/a.deb")
      expect(cache.entries[:entries].map(&.key)).to eq(["mirror/b.deb"])
      cache.clear
      expect(cache.entries[:entries]).to be_empty
    end
  end
end
