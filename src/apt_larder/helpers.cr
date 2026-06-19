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

  # Parses a CONNECT authority (`host:port`) into `{host, port}`.
  #
  # Handles IPv6 literals: the brackets of `[::1]:8443` are stripped and the
  # port that follows the closing bracket is parsed, so an address containing
  # colons is never split on the wrong one. A bracketed literal without a port
  # (`[::1]`) and a bare host without a port both fall back to port 443.
  def self.parse_connect_target(resource : String) : {String, Int32}
    if resource.starts_with?('[') && (close = resource.index(']'))
      host = resource[1...close]
      rest = resource[(close + 1)..]
      port = rest.starts_with?(':') ? (rest[1..].to_i? || 443) : 443
      return {host, port}
    end
    pre, sep, post = resource.rpartition(':')
    # No colon: rpartition leaves the whole string in *post*.
    sep.empty? ? {post, 443} : {pre, post.to_i? || 443}
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
