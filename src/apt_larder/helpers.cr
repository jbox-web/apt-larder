module AptLarder
  # Shared buffer size for all IO copy operations.
  # 64 KB reduces syscall overhead by 8× vs Crystal's default 8 KB.
  COPY_BUFFER_SIZE = 64 * 1024

  # Returns `true` for cache keys that APT guarantees are immutable once
  # published: `.deb` packages, content-addressed index files (`/by-hash/`)
  # and the named files of a pool (`/pool/…/curl_8.5.0.orig.tar.gz`).
  #
  # A pool path whose last segment has no extension (`/pool/main/c/curl`) is a
  # directory: what a mirror serves there is its index page, which changes
  # with every upload and must not be kept forever.
  def self.immutable?(key : String) : Bool
    return true if key.ends_with?(".deb") || key.ends_with?(".udeb") || key.ends_with?(".ddeb")
    return true if key.includes?("/by-hash/")
    key.includes?("/pool/") && File.basename(key).includes?('.')
  end

  # Raised when a client asks the proxy to reach a target the policy forbids
  # (a local address, or a CONNECT port outside the allowed list).
  class ForbiddenTarget < Exception
  end

  # Parses a CONNECT authority (`host:port`) into `{host, port}`.
  #
  # Handles IPv6 literals: the brackets of `[::1]:8443` are stripped and the
  # port that follows the closing bracket is parsed, so an address containing
  # colons is never split on the wrong one. A bracketed literal without a port
  # (`[::1]`) and a bare host without a port both fall back to port 443.
  #
  # Raises `ArgumentError` when a port is given but is not a number in
  # 1..65535: guessing 443 would open a tunnel the client never asked for.
  def self.parse_connect_target(resource : String) : {String, Int32}
    if resource.starts_with?('[') && (close = resource.index(']'))
      host = resource[1...close]
      rest = resource[(close + 1)..]
      port = rest.starts_with?(':') ? parse_port(rest[1..]) : 443
      return {host, port}
    end
    pre, sep, post = resource.rpartition(':')
    # No colon: rpartition leaves the whole string in *post*.
    sep.empty? ? {post, 443} : {pre, parse_port(post)}
  end

  private def self.parse_port(value : String) : Int32
    port = value.to_i?
    raise ArgumentError.new("invalid port '#{value}'") unless port && port.in?(1..65535)
    port
  end

  # Returns `true` for an address that designates the proxy's own host or its
  # link: loopback, the unspecified address (dialling `0.0.0.0` reaches the
  # local host), and link-local (where cloud instance metadata lives).
  # IPv4-mapped IPv6 forms (`::ffff:127.0.0.1`) are judged as the IPv4 address
  # they carry. Private ranges are NOT local: a mirror on the LAN is the
  # normal case.
  def self.local_address?(ip : Socket::IPAddress) : Bool
    if (mapped = ip.address.lchop?("::ffff:")) && Socket::IPAddress.valid_v4?(mapped)
      ip = Socket::IPAddress.new(mapped, ip.port)
    end
    ip.loopback? || ip.unspecified? || ip.link_local?
  end

  # Returns `true` when *host* is, or resolves to, at least one local address
  # (see `local_address?`). One local answer among several is enough: the
  # connection could land on it.
  #
  # Raises `Socket::Addrinfo::Error` when *host* does not resolve.
  def self.local_target?(host : String, port : Int32) : Bool
    Socket::Addrinfo.tcp(host, port).any? { |info| local_address?(info.ip_address) }
  end

  # Formats *n* bytes as a human-readable string in binary units
  # (`1.2 KiB`, `45.3 MiB`, …) — the same units and labels as the web UI.
  def self.format_bytes(n : Int64) : String
    case n
    when .>= 1_073_741_824 then "#{(n / 1_073_741_824.0).round(1)} GiB"
    when .>= 1_048_576     then "#{(n / 1_048_576.0).round(1)} MiB"
    when .>= 1_024         then "#{(n / 1_024.0).round(1)} KiB"
    else                        "#{n} B"
    end
  end
end
