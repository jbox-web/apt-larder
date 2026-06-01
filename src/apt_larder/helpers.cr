module AptLarder
  # Shared buffer size for all IO copy operations.
  # 64 KB reduces syscall overhead by 8× vs Crystal's default 8 KB.
  COPY_BUFFER_SIZE = 64 * 1024

  # Returns `true` for cache keys that APT guarantees are immutable once
  # published: `.deb` packages and content-addressed paths (`/pool/`,
  # `/by-hash/`).
  def self.immutable?(key : String) : Bool
    key.ends_with?(".deb") || key.ends_with?(".udeb") ||
      key.ends_with?(".ddeb") || key.includes?("/pool/") ||
      key.includes?("/by-hash/")
  end

  # Formats *n* bytes as a human-readable string (`1.2 KB`, `45.3 MB`, …).
  def self.format_bytes(n : Int64) : String
    case n
    when .>= 1_073_741_824 then "#{(n / 1_073_741_824.0).round(1)} GB"
    when .>= 1_048_576     then "#{(n / 1_048_576.0).round(1)} MB"
    when .>= 1_024         then "#{(n / 1_024.0).round(1)} KB"
    else                        "#{n} B"
    end
  end
end
