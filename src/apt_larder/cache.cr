module AptLarder
  # Filesystem-backed cache for APT packages and index files.
  #
  # Each entry is stored as a plain file under `root` using the cache key as a
  # relative path. A `.sha256` sidecar is written alongside every file so that
  # immutable entries can be verified on first serve without trusting the
  # filesystem alone. A `.validators` sidecar keeps the upstream `Last-Modified`
  # and `ETag` of an entry, so revalidation replays what upstream sent instead
  # of a local timestamp.
  #
  # In-memory indices avoid redundant syscalls at runtime:
  # - `@known` — keys confirmed present on disk
  # - `@mtime_cache` — last-modified times, updated by `store` and `touch`
  # - `@verified` — keys whose SHA256 has already been checked this session
  # - `@used_at` — when `mark_used` last refreshed a key's mtime on disk
  #
  # All public methods are safe to call from concurrent fibers. The process is
  # single-threaded, so the long loops here (directory scans, hashing) hand
  # control back to the scheduler at regular intervals: without that, every
  # other request would wait for them to finish.
  class Cache
    Log = ::Log.for("apt-larder.cache")

    VALIDATORS_SUFFIX = ".validators"

    # Shape of the temporary name `store` downloads into before renaming:
    # `<dest>.<16 hex digits>.tmp`.
    TEMP_PATTERN = /\.[0-9a-f]{16}\.tmp\z/

    # Minimum time between two on-disk mtime refreshes of the same key by
    # `mark_used`. Bounds the metadata writes a popular package costs to one
    # per hour, which is also the period of the eviction loop.
    USED_REFRESH_INTERVAL = 1.hour

    # How long a directory listing built for `entries` is reused. Paging
    # through a large cache, or typing in the admin search box, then costs one
    # disk scan instead of one per request.
    LISTING_TTL = 5.seconds

    # Number of files a scan processes before yielding to other fibers.
    SCAN_YIELD_EVERY = 1000

    # Number of buffers (`COPY_BUFFER_SIZE` each, i.e. 4 MB) hashed before
    # yielding to other fibers.
    HASH_YIELD_EVERY = 64

    # Every file kept alongside a data file. Scans skip them, and removing an
    # entry removes all of them.
    SIDECAR_SUFFIXES = {".sha256", VALIDATORS_SUFFIX}

    # Returns `true` for a path or key ending with a sidecar suffix. Sidecars
    # belong to a data file and are never entries of their own; they share the
    # key namespace, so the proxy must never read or write such a key.
    #
    # Case-insensitive: on APFS or a Docker Desktop bind mount `Release.SHA256`
    # is the very file `Release.sha256`.
    def self.sidecar?(path : String) : Bool
      path = path.downcase
      SIDECAR_SUFFIXES.any? { |suffix| path.ends_with?(suffix) }
    end

    # Returns `true` for a path or key shaped like the temporary file of a
    # download in flight. Like sidecars, these share the key namespace without
    # being entries: scans skip them and the proxy never stores such a key.
    def self.temp?(path : String) : Bool
      path.matches?(TEMP_PATTERN)
    end

    # *root* is normalized (`/var/cache/apt-larder/` and `./cache` become
    # `/var/cache/apt-larder` and `cache`): keys are derived from the paths a
    # scan returns by stripping the root, which only works when both are
    # written the same way.
    #
    # With *scan* (the default) the entry and size gauges are seeded from a
    # disk scan before the constructor returns. A server that must not delay
    # its startup on a large cache passes `scan: false` and calls `rescan` once
    # it is listening.
    def initialize(root : String, scan : Bool = true)
      @root = Path[root].normalize.to_s
      Dir.mkdir_p(@root)
      @mutex = Mutex.new
      @known = Set(String).new
      @mtime_cache = {} of String => Time
      @verified = Set(String).new
      @used_at = {} of String => Time::Instant
      @listing = nil.as({Array(EntryInfo), Time::Instant}?)
      @entry_count = 0
      @total_bytes = 0_i64
      rescan if scan
    end

    # Seeds the authoritative entry and size gauges from a disk scan, so the
    # Prometheus `cache_entries` and `cache_bytes` gauges reflect a warm cache
    # instead of starting at 0 and climbing as requests arrive. O(1) memory
    # (two integers, no Set). Also removes the temporary files a previous run
    # left behind.
    #
    # Meant to run once, at startup: a temporary file found here cannot belong
    # to a download of this process. `evict` re-anchors the gauges afterwards.
    def rescan : Nil
      count, bytes = scan_disk
      @mutex.synchronize do
        @entry_count = count
        @total_bytes = bytes
      end
    end

    # Returns `true` if a file for *key* exists on disk. A directory is not an
    # entry, even though entries live below it.
    #
    # Checks the in-memory `@known` set first to avoid a `stat` syscall on
    # repeated lookups. Adds the key to `@known` on the first disk hit.
    def exists?(key : String) : Bool
      return true if @mutex.synchronize { @known.includes?(key) }
      result = File.file?(path_for(key))
      @mutex.synchronize { @known.add(key) } if result
      result
    end

    # Returns `true` if *key* names a directory of the cache — a path other
    # entries live below, which can therefore not be an entry itself.
    def directory?(key : String) : Bool
      File.directory?(path_for(key))
    end

    # Returns `true` if the cached file for *key* is younger than *ttl*.
    #
    # Uses the in-memory mtime index when available, falling back to a single
    # `stat` call on first access. Returns `false` if the key is not cached.
    def fresh?(key : String, ttl : Time::Span) : Bool
      # TTL=0 means "always stale" — avoids a race where mtime ≈ Time.utc.
      return false if ttl <= Time::Span.zero
      mtime = @mutex.synchronize { @mtime_cache[key]? }
      unless mtime
        mtime = modification_time?(key)
        return false unless mtime
        @mutex.synchronize { @mtime_cache[key] = mtime }
      end
      mtime > Time.utc - ttl
    end

    # Returns the modification time of the cached file, or `nil` if the file
    # does not exist or disappears between the call and the `stat` (TOCTOU safe).
    def modification_time?(key : String) : Time?
      File.info(path_for(key)).modification_time
    rescue File::Error
      nil
    end

    # Updates the mtime of *key* to the current time and refreshes the in-memory
    # index. Used to extend the freshness window after a 304 Not Modified response.
    # Silently ignores missing files.
    def touch(key : String) : Nil
      p = path_for(key)
      now = Time.utc
      File.utime(now, now, p)
      @mutex.synchronize { @mtime_cache[key] = now }
    rescue File::Error
    end

    # Records that *key* was just served, by bringing its mtime back to now —
    # the timestamp eviction sorts on, which makes `evict_after_days` mean "not
    # accessed for N days" and size-based eviction a real LRU.
    #
    # Writes to disk at most once per `USED_REFRESH_INTERVAL` for a given key.
    # Only for immutable entries: the mtime of an index file is its freshness
    # clock (see `fresh?`), which a hit must not move.
    # Silently ignores missing files.
    def mark_used(key : String) : Nil
      now = Time.instant
      due = @mutex.synchronize do
        last = @used_at[key]?
        next false if last && now - last < USED_REFRESH_INTERVAL
        @used_at[key] = now
        true
      end
      return unless due
      stamp = Time.utc
      File.utime(stamp, stamp, path_for(key))
    rescue File::Error
      @mutex.synchronize { @used_at.delete(key) }
    end

    # Upstream cache validators of an entry, stored verbatim as received so they
    # can be echoed back unchanged in `If-Modified-Since` / `If-None-Match`.
    record Validators, last_modified : String?, etag : String?

    # Returns the upstream validators stored for *key*, or `nil` when the entry
    # has none (missing entry, upstream sent neither header, or entry cached
    # before validators were recorded).
    def validators(key : String) : Validators?
      last_modified = nil
      etag = nil
      File.each_line("#{path_for(key)}#{VALIDATORS_SUFFIX}") do |line|
        name, _, value = line.partition(": ")
        case name
        when "Last-Modified" then last_modified = value
        when "ETag"          then etag = value
        end
      end
      return nil unless last_modified || etag
      Validators.new(last_modified, etag)
    rescue File::Error
      nil
    end

    # Streams *io* into the cache under *key*.
    #
    # Writes to a randomly-named `.tmp` file first, then renames it into place
    # atomically. The SHA256 of the content is computed during the write at no
    # extra I/O cost and stored in a `.sha256` sidecar file.
    #
    # *last_modified* and *etag* are the upstream response validators; they are
    # kept in a `.validators` sidecar, which is removed when neither is given so
    # a re-stored entry never keeps the validators of its previous content.
    #
    # If the write fails for any reason (network drop, disk full, …) the `.tmp`
    # file is deleted and the exception is re-raised. The destination is never
    # left in a partially-written state.
    #
    # A mirror can answer 200 both for `…/curl` (its index page) and for
    # `…/curl/curl_8.deb`: the same name is then wanted as a file and as a
    # directory. Entries below win: a cached file standing where a directory is
    # needed is invalidated, and storing onto an existing directory raises
    # `File::Error` before anything is written.
    def store(key : String, io : IO, last_modified : String? = nil, etag : String? = nil) : Nil
      dest = path_for(key)
      if File.directory?(dest)
        raise File::Error.new("Cannot cache '#{key}': it is a directory holding other entries", file: dest)
      end
      make_parent_directory(key, dest)
      tmp = "#{dest}.#{Random::Secure.hex(8)}.tmp"
      begin
        buf = Bytes.new(COPY_BUFFER_SIZE)
        digest = Digest::SHA256.new
        written = 0_i64
        File.open(tmp, "w") do |file|
          loop do
            n = io.read(buf)
            break if n == 0
            file.write(buf[0, n])
            digest.update(buf[0, n])
            written += n
          end
        end
        hash = digest.hexfinal
        # Write the sidecar before publishing the data file. If the process
        # crashes between the two operations, the worst case is a sidecar with
        # no (or stale) data file, which valid? rejects (File::Error / mismatch)
        # so the entry is re-downloaded. The reverse order could leave a data
        # file with no sidecar, which valid? would trust and serve unverified.
        File.write("#{dest}.sha256", hash)
        # Detect an overwrite before publishing so the entry gauge counts a
        # given key once and the size gauge swaps the old size for the new one.
        # Single-flight guarantees no concurrent store for the same key, so
        # this check is race-free.
        previous_size = File.info?(dest).try(&.size)
        File.rename(tmp, dest)
        # Written after the data file is published. A crash in between leaves
        # the new data with the previous (or no) validators: the next
        # revalidation then gets a 200 and heals the entry. The reverse order
        # could pair new validators with old data, which a 304 would pin forever.
        write_validators(dest, last_modified, etag)
        now = Time.utc
        @mutex.synchronize do
          @known.add(key)
          @mtime_cache[key] = now
          # just written and hashed — no need to re-verify on first serve
          @verified.add(key)
          @entry_count += 1 unless previous_size
          @total_bytes += written - (previous_size || 0_i64)
          @listing = nil
        end
      rescue ex
        File.delete(tmp) if File.exists?(tmp)
        raise ex
      end
    end

    # Returns `true` if the cached file matches its stored SHA256 sidecar.
    #
    # Files that have no sidecar (written before integrity tracking was added)
    # are trusted unconditionally. Each file is hashed at most once per server
    # run: after the first successful check the key is added to `@verified` and
    # subsequent calls return immediately.
    def valid?(key : String) : Bool
      return true if @mutex.synchronize { @verified.includes?(key) }
      path = path_for(key)
      hash_path = "#{path}.sha256"
      unless File.exists?(hash_path)
        # No sidecar means the file predates integrity tracking — trust it.
        @mutex.synchronize { @verified.add(key) }
        return true
      end
      expected = File.read(hash_path).strip
      actual = sha256_of(path)
      if actual == expected
        @mutex.synchronize { @verified.add(key) }
        true
      else
        Log.warn { "integrity check failed: #{key}" }
        false
      end
    rescue File::Error
      # The file or its sidecar disappeared between the existence check and the
      # read/hash (e.g. concurrent eviction). Treat as invalid so the caller
      # re-downloads instead of letting the exception escape onto the hot path.
      false
    end

    # Returns `true` if *key*'s SHA256 has already been verified this session.
    # O(1) and does no disk I/O: used as a fast pre-check before the
    # single-flight so the expensive `valid?` hashing runs at most once per key.
    def verified?(key : String) : Bool
      @mutex.synchronize { @verified.includes?(key) }
    end

    # Removes the file and its sidecars from disk and clears all in-memory
    # state for *key*. Safe to call when the file does not exist.
    #
    # Returns `true` only if this call actually removed the data file.
    def invalidate(key : String) : Bool
      # Defense in depth: a key containing ".." could resolve outside the cache
      # root and delete an arbitrary file. Callers should sanitize, but never
      # trust them here — this is a destructive operation.
      return false if key.includes?("..")
      @mutex.synchronize do
        @known.delete(key)
        @mtime_cache.delete(key)
        @verified.delete(key)
        @used_at.delete(key)
        @listing = nil
      end
      path = path_for(key)
      # Read before the delete: the size is gone once the file is.
      size = File.info?(path).try(&.size) || 0_i64
      # The delete result is the source of truth for the gauges: on a concurrent
      # double-invalidate exactly one call actually removes the file (the other
      # raises File::Error), so they are decremented exactly once.
      data_deleted = delete_file?(path)
      SIDECAR_SUFFIXES.each { |suffix| delete_file?("#{path}#{suffix}") }
      @mutex.synchronize do
        if data_deleted
          @entry_count -= 1
          @total_bytes -= size
        end
      end
      data_deleted
    end

    # Removes every cached entry (data files and their sidecars) in a single
    # directory scan and clears all in-memory state. Returns the number of data
    # files deleted.
    #
    # Unlike iterating `entries` + `invalidate`, this builds no per-entry structs
    # and holds the whole listing only as a glob stream, so it stays cheap on
    # very large caches. Best-effort under concurrency: entries added while the
    # scan runs may survive (acceptable for an admin flush).
    def clear : Int32
      deleted = 0
      each_data_file do |path, _|
        File.delete(path) rescue next
        SIDECAR_SUFFIXES.each { |suffix| File.delete("#{path}#{suffix}") rescue nil }
        deleted += 1
      end
      @mutex.synchronize do
        @known.clear
        @mtime_cache.clear
        @verified.clear
        @used_at.clear
        @listing = nil
        @entry_count = 0
        @total_bytes = 0_i64
      end
      deleted
    end

    # Deletes every cached file whose mtime is older than *max_age*.
    #
    # The mtime is the time of the last download, revalidation or (through
    # `mark_used`) hit, so both passes evict by last access.
    #
    # Skips `.sha256` and `.validators` sidecar files (they are removed
    # together with their parent by `invalidate`) and downloads in flight.
    # Performs time-based and/or size-based eviction in a single disk scan.
    # Only files this call actually removed are counted.
    #
    # - *max_age* — delete files whose mtime is older than this span (`nil` = skip)
    # - *limit_bytes* — delete LRU files until total size is below this limit (`nil` = skip)
    #
    # Returns `{files_deleted, bytes_freed}`.
    def evict(max_age : Time::Span? = nil, limit_bytes : Int64? = nil) : {Int32, Int64}
      return {0, 0_i64} unless max_age || limit_bytes

      cutoff = max_age ? Time.utc - max_age : nil
      candidates = [] of {String, Int64, Time}
      total_bytes = 0_i64

      each_data_file do |path, info|
        candidates << {key_for(path), info.size, info.modification_time}
        total_bytes += info.size
      end

      # Re-anchor the gauges to the authoritative on-disk count and size seen by
      # this scan, correcting any drift accumulated since boot. The invalidate
      # calls below each decrement them further as files are removed.
      @mutex.synchronize do
        @entry_count = candidates.size
        @total_bytes = total_bytes
      end

      deleted = 0
      freed = 0_i64

      # Time-based pass: remove files older than cutoff regardless of total size.
      if cutoff
        candidates.reject! do |key, size, mtime|
          next false unless mtime < cutoff
          # Still dropped from the candidates when the delete fails: the size
          # pass must not try the same file again.
          next true unless invalidate(key)
          freed += size
          total_bytes -= size
          deleted += 1
          true
        end
      end

      # Size-based pass: remove LRU files until under the limit.
      if limit_bytes && total_bytes > limit_bytes
        candidates.sort_by! { |_, _, mtime| mtime }
        candidates.each do |key, size, _|
          break if total_bytes <= limit_bytes
          next unless invalidate(key)
          freed += size
          total_bytes -= size
          deleted += 1
        end
      end

      {deleted, freed}
    end

    # Convenience wrapper: time-based eviction only.
    def evict_stale(max_age : Time::Span) : {Int32, Int64}
      evict(max_age: max_age)
    end

    # Convenience wrapper: size-based LRU eviction only.
    def evict_to_limit(limit_bytes : Int64) : {Int32, Int64}
      evict(limit_bytes: limit_bytes)
    end

    # Returns the number of cached data files.
    #
    # Fast (no disk scan): maintained incrementally by `store`/`invalidate`/
    # `clear`, seeded from disk at construction, and re-anchored to the exact
    # on-disk count on every `evict` pass. May drift slightly between eviction
    # passes if files are added or removed out-of-band.
    def entry_count : Int32
      @mutex.synchronize { @entry_count }
    end

    # Returns the summed byte size of the cached data files, sidecars excluded:
    # the same figure `max_cache_size_gb` is enforced against.
    #
    # Fast (no disk scan): maintained alongside `entry_count`, by the same
    # operations and with the same drift caveat.
    def total_bytes : Int64
      @mutex.synchronize { @total_bytes }
    end

    # Returns the byte size of the cached file for *key*.
    # Raises `File::Error` if the key is not present.
    def size(key : String) : Int64
      File.size(path_for(key))
    end

    # Opens the cached file for *key* in read-only mode.
    # Raises `File::Error` if the key is not present.
    def open(key : String) : File
      File.open(path_for(key), "r")
    end

    struct EntryInfo
      include JSON::Serializable
      getter key : String
      getter size : Int64
      getter mtime : Time
      getter? immutable : Bool

      def initialize(@key, @size, @mtime, @immutable)
      end
    end

    # Column `entries` is ordered by.
    enum EntrySort
      Key
      Size
      Mtime
    end

    # Returns paginated cache entries, optionally filtered by *prefix* and by
    # *search*, a case-insensitive substring of the key. Entries are ordered by
    # *sort* (ties broken by key), reversed when *descending*, and only then
    # paginated; `total` counts the entries left after filtering.
    #
    # The directory listing behind it is scanned once and reused for
    # `LISTING_TTL` (and dropped at once by `store`, `invalidate` and `clear`),
    # so walking the pages of a large cache does not rescan it for each page.
    # A page beyond the last one is empty.
    def entries(prefix : String = "", page : Int32 = 1, per_page : Int32 = 50,
                search : String = "", sort : EntrySort = EntrySort::Key,
                descending : Bool = false) : {entries: Array(EntryInfo), total: Int32}
      needle = search.downcase
      all = listing.select do |entry|
        (prefix.empty? || entry.key.starts_with?(prefix)) &&
          (needle.empty? || entry.key.downcase.includes?(needle))
      end
      case sort
      in .key?   then all.sort_by!(&.key)
      in .size?  then all.sort_by! { |entry| {entry.size, entry.key} }
      in .mtime? then all.sort_by! { |entry| {entry.mtime, entry.key} }
      end
      all.reverse! if descending
      # Int64: page * per_page overflows Int32 long before page does.
      offset = (page.to_i64 - 1) * per_page
      page_entries = offset < all.size ? all[offset.to_i, per_page] : [] of EntryInfo
      {entries: page_entries, total: all.size}
    end

    private def immutable?(key : String) : Bool
      AptLarder.immutable?(key)
    end

    # Deletes *path*, returning `true` only if this call actually removed the
    # file. A missing file (already gone, or removed by a concurrent caller)
    # yields `false` instead of raising.
    private def delete_file?(path : String) : Bool
      File.delete(path)
      true
    rescue File::Error
      false
    end

    # Counts data files (excluding sidecars) under the cache root and sums
    # their sizes in a single streaming glob, deleting the temporary files of
    # a previous run on the way. O(1) memory. Returns `{count, bytes}`.
    private def scan_disk : {Int32, Int64}
      count = 0
      bytes = 0_i64
      each_data_file(purge_temp: true) do |_, info|
        count += 1
        bytes += info.size
      end
      {count, bytes}
    end

    # Yields the path and `File::Info` of every data file under the root:
    # sidecars, temporary download files and directories are skipped, and so
    # is a file that vanishes mid-scan. One `stat` per file. Yields to other
    # fibers every `SCAN_YIELD_EVERY` files.
    #
    # With *purge_temp*, temporary files are deleted instead of merely skipped.
    private def each_data_file(purge_temp : Bool = false, &) : Nil
      seen = 0
      Dir.glob("#{@root}/**/*") do |path|
        seen += 1
        Fiber.yield if seen % SCAN_YIELD_EVERY == 0
        next if Cache.sidecar?(path)
        if Cache.temp?(path)
          delete_file?(path) if purge_temp
          next
        end
        info = File.info?(path)
        next unless info && info.file?
        yield path, info
      end
    end

    # Returns every entry of the cache, from the snapshot when it is younger
    # than `LISTING_TTL`, from a fresh scan otherwise.
    private def listing : Array(EntryInfo)
      cached = @mutex.synchronize { @listing }
      return cached[0] if cached && Time.instant - cached[1] < LISTING_TTL
      all = [] of EntryInfo
      each_data_file do |path, info|
        key = key_for(path)
        all << EntryInfo.new(key, info.size, info.modification_time, immutable?(key))
      end
      @mutex.synchronize { @listing = {all, Time.instant} }
      all
    end

    private def path_for(key : String) : String
      File.join(@root, key)
    end

    # Inverse of `path_for` for a path returned by a scan of the root.
    private def key_for(path : String) : String
      path.lchop("#{@root}/")
    end

    # Creates the directory *dest* (the data file of *key*) lives in. When an
    # ancestor of *key* is itself a cached file — the index page of that
    # directory — that entry is invalidated to make room and the creation is
    # tried once more.
    private def make_parent_directory(key : String, dest : String) : Nil
      Dir.mkdir_p(File.dirname(dest))
    rescue File::Error
      ancestor = key
      while slash = ancestor.rindex('/')
        ancestor = ancestor[0, slash]
        next unless File.file?(path_for(ancestor))
        Log.warn { "#{ancestor} was cached as a file but is a directory of #{key}: dropping it" }
        invalidate(ancestor)
      end
      Dir.mkdir_p(File.dirname(dest))
    end

    # Writes the `.validators` sidecar of the data file at *path*, or removes it
    # when upstream sent no validator.
    #
    # Best effort: the data file is already published, so a failure here only
    # logs. A missing or truncated sidecar makes the next revalidation an
    # unconditional GET, which heals the entry. Rescues IO::Error rather than
    # File::Error: a failed write or close (ENOSPC, EIO) raises a plain
    # IO::Error, of which File::Error (open failures) is only a subclass.
    private def write_validators(path : String, last_modified : String?, etag : String?) : Nil
      sidecar = "#{path}#{VALIDATORS_SUFFIX}"
      unless last_modified || etag
        # Checked first: most stores (every package) have no sidecar, and
        # delete_file? would raise and rescue a File::Error for each of them.
        delete_file?(sidecar) if File.exists?(sidecar)
        return
      end
      File.open(sidecar, "w") do |file|
        file << "Last-Modified: " << last_modified << '\n' if last_modified
        file << "ETag: " << etag << '\n' if etag
      end
    rescue ex : IO::Error
      Log.warn { "cannot write validators for #{path}: #{ex.message}" }
      delete_file?(sidecar) if sidecar
    end

    private def sha256_of(path : String) : String
      digest = Digest::SHA256.new
      buf = Bytes.new(COPY_BUFFER_SIZE)
      File.open(path, "r") do |file|
        chunks = 0
        loop do
          n = file.read(buf)
          break if n == 0
          digest.update(buf[0, n])
          chunks += 1
          Fiber.yield if chunks % HASH_YIELD_EVERY == 0
        end
      end
      digest.hexfinal
    end
  end
end
