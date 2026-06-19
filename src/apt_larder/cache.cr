module AptLarder
  # Filesystem-backed cache for APT packages and index files.
  #
  # Each entry is stored as a plain file under `root` using the cache key as a
  # relative path. A `.sha256` sidecar is written alongside every file so that
  # immutable entries can be verified on first serve without trusting the
  # filesystem alone.
  #
  # Three in-memory indices avoid redundant syscalls at runtime:
  # - `@known` — keys confirmed present on disk (never shrinks while running)
  # - `@mtime_cache` — last-modified times, updated by `store` and `touch`
  # - `@verified` — keys whose SHA256 has already been checked this session
  #
  # All public methods are safe to call from concurrent fibers.
  class Cache
    Log = ::Log.for("apt-larder.cache")

    def initialize(@root : String)
      Dir.mkdir_p(@root)
      @mutex = Mutex.new
      @known = Set(String).new
      @mtime_cache = {} of String => Time
      @verified = Set(String).new
    end

    # Returns `true` if a file for *key* exists on disk.
    #
    # Checks the in-memory `@known` set first to avoid a `stat` syscall on
    # repeated lookups. Adds the key to `@known` on the first disk hit.
    def exists?(key : String) : Bool
      return true if @mutex.synchronize { @known.includes?(key) }
      result = File.exists?(path_for(key))
      @mutex.synchronize { @known.add(key) } if result
      result
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

    # Streams *io* into the cache under *key*.
    #
    # Writes to a randomly-named `.tmp` file first, then renames it into place
    # atomically. The SHA256 of the content is computed during the write at no
    # extra I/O cost and stored in a `.sha256` sidecar file.
    #
    # If the write fails for any reason (network drop, disk full, …) the `.tmp`
    # file is deleted and the exception is re-raised. The destination is never
    # left in a partially-written state.
    def store(key : String, io : IO) : Nil
      dest = path_for(key)
      Dir.mkdir_p(File.dirname(dest))
      tmp = "#{dest}.#{Random::Secure.hex(8)}.tmp"
      begin
        buf = Bytes.new(COPY_BUFFER_SIZE)
        digest = Digest::SHA256.new
        File.open(tmp, "w") do |file|
          loop do
            n = io.read(buf)
            break if n == 0
            file.write(buf[0, n])
            digest.update(buf[0, n])
          end
        end
        hash = digest.hexfinal
        File.rename(tmp, dest)
        File.write("#{dest}.sha256", hash)
        now = Time.utc
        @mutex.synchronize do
          @known.add(key)
          @mtime_cache[key] = now
          # just written and hashed — no need to re-verify on first serve
          @verified.add(key)
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

    # Removes the file and its `.sha256` sidecar from disk and clears all
    # in-memory state for *key*. Safe to call when the file does not exist.
    def invalidate(key : String) : Nil
      @mutex.synchronize do
        @known.delete(key)
        @mtime_cache.delete(key)
        @verified.delete(key)
      end
      path = path_for(key)
      File.delete(path) rescue nil
      File.delete("#{path}.sha256") rescue nil
    end

    # Deletes every cached file whose mtime is older than *max_age*.
    #
    # Skips `.sha256` sidecar files (they are removed together with their
    # parent by `invalidate`). Returns `{files_deleted, bytes_freed}`.
    # Performs time-based and/or size-based eviction in a single disk scan.
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

      Dir.glob("#{@root}/**/*") do |path|
        next if path.ends_with?(".sha256")
        next unless File.file?(path)
        info = File.info(path) rescue next
        key = path[(@root.size + 1)..]
        candidates << {key, info.size, info.modification_time}
        total_bytes += info.size
      end

      deleted = 0
      freed = 0_i64

      # Time-based pass: remove files older than cutoff regardless of total size.
      if cutoff
        candidates.reject! do |key, size, mtime|
          next false unless mtime < cutoff
          invalidate(key)
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
          invalidate(key)
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

    # Returns the number of files currently tracked in the in-memory index.
    # Fast (no disk scan); may be slightly lower than actual disk count if
    # files were added externally.
    def entry_count : Int32
      @mutex.synchronize { @known.size }
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

    # Returns paginated cache entries, optionally filtered by *prefix*.
    # Scans the root directory on each call — intended for infrequent admin use.
    def entries(prefix : String = "", page : Int32 = 1, per_page : Int32 = 50) : {entries: Array(EntryInfo), total: Int32}
      all = [] of EntryInfo
      Dir.glob("#{@root}/**/*") do |path|
        next if path.ends_with?(".sha256")
        next unless File.file?(path)
        key = path[(@root.size + 1)..]
        next unless prefix.empty? || key.starts_with?(prefix)
        mtime = File.info(path).modification_time rescue next
        size = File.size(path) rescue next
        all << EntryInfo.new(key, size, mtime, immutable?(key))
      end
      all.sort_by!(&.key)
      offset = (page - 1) * per_page
      {entries: all[offset, per_page]? || [] of EntryInfo, total: all.size}
    end

    private def immutable?(key : String) : Bool
      AptLarder.immutable?(key)
    end

    private def path_for(key : String) : String
      File.join(@root, key)
    end

    private def sha256_of(path : String) : String
      digest = Digest::SHA256.new
      buf = Bytes.new(COPY_BUFFER_SIZE)
      File.open(path, "r") do |file|
        loop do
          n = file.read(buf)
          break if n == 0
          digest.update(buf[0, n])
        end
      end
      digest.hexfinal
    end
  end
end
