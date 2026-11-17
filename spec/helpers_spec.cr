require "./spec_helper"

Spectator.describe "AptLarder.parse_connect_target" do
  it "parses a plain host:port" do
    expect(AptLarder.parse_connect_target("deb.debian.org:443")).to eq({"deb.debian.org", 443})
  end

  it "defaults to port 443 when no port is given" do
    expect(AptLarder.parse_connect_target("deb.debian.org")).to eq({"deb.debian.org", 443})
  end

  it "strips brackets and parses the port of an IPv6 literal" do
    expect(AptLarder.parse_connect_target("[2001:db8::1]:8443")).to eq({"2001:db8::1", 8443})
  end

  it "handles a bracketed IPv6 literal without a port" do
    expect(AptLarder.parse_connect_target("[::1]")).to eq({"::1", 443})
  end

  it "does not split an IPv6 literal on an inner colon" do
    expect(AptLarder.parse_connect_target("[::1]:443")).to eq({"::1", 443})
  end

  it "raises on a non-numeric port instead of guessing 443" do
    expect { AptLarder.parse_connect_target("host:bogus") }.to raise_error(ArgumentError)
  end

  it "raises on a non-numeric port after an IPv6 literal" do
    expect { AptLarder.parse_connect_target("[::1]:bogus") }.to raise_error(ArgumentError)
  end

  it "raises on a port outside 1-65535" do
    expect { AptLarder.parse_connect_target("host:70000") }.to raise_error(ArgumentError)
    expect { AptLarder.parse_connect_target("host:0") }.to raise_error(ArgumentError)
  end
end

Spectator.describe "AptLarder.local_address?" do
  private def local?(address : String) : Bool
    AptLarder.local_address?(Socket::IPAddress.new(address, 80))
  end

  it "is true for loopback addresses" do
    expect(local?("127.0.0.1")).to be_true
    expect(local?("127.8.9.10")).to be_true
    expect(local?("::1")).to be_true
  end

  it "is true for the unspecified address, which dials the local host" do
    expect(local?("0.0.0.0")).to be_true
    expect(local?("::")).to be_true
  end

  it "is true for link-local addresses" do
    expect(local?("169.254.169.254")).to be_true
    expect(local?("fe80::1")).to be_true
  end

  it "is true for IPv4-mapped IPv6 forms of local addresses" do
    expect(local?("::ffff:127.0.0.1")).to be_true
    expect(local?("::ffff:169.254.169.254")).to be_true
    expect(local?("::ffff:0.0.0.0")).to be_true
  end

  it "is false for private and public addresses" do
    expect(local?("192.168.1.10")).to be_false
    expect(local?("10.0.0.1")).to be_false
    expect(local?("172.16.0.1")).to be_false
    expect(local?("8.8.8.8")).to be_false
    expect(local?("2001:db8::1")).to be_false
    expect(local?("::ffff:192.168.1.10")).to be_false
  end
end

Spectator.describe "AptLarder.local_target?" do
  it "is true for a loopback literal" do
    expect(AptLarder.local_target?("127.0.0.1", 80)).to be_true
  end

  it "is true for a name resolving to loopback" do
    expect(AptLarder.local_target?("localhost", 80)).to be_true
  end

  it "is false for a routable literal" do
    expect(AptLarder.local_target?("192.0.2.1", 80)).to be_false
  end
end

Spectator.describe "AptLarder.immutable?" do
  it "is true for each package extension, wherever the file lives" do
    expect(AptLarder.immutable?("mirror/x/pkg.deb")).to be_true
    expect(AptLarder.immutable?("mirror/x/pkg.udeb")).to be_true
    expect(AptLarder.immutable?("mirror/x/pkg.ddeb")).to be_true
  end

  it "is true for content-addressed index files" do
    expect(AptLarder.immutable?("mirror/dists/stable/by-hash/SHA256/abc")).to be_true
  end

  it "is true for any named file of a pool (sources, signatures)" do
    expect(AptLarder.immutable?("mirror/debian/pool/main/c/curl/curl_8.5.0.orig.tar.gz")).to be_true
    expect(AptLarder.immutable?("mirror/debian/pool/main/c/curl/curl_8.5.0-2.dsc")).to be_true
  end

  # A pool path without an extension is a directory: what a mirror serves
  # there is its index page, which changes with every upload.
  it "is false for a directory of a pool" do
    expect(AptLarder.immutable?("mirror/debian/pool/main/c/curl")).to be_false
    expect(AptLarder.immutable?("mirror/debian/pool/main")).to be_false
  end

  it "is false for index files" do
    expect(AptLarder.immutable?("mirror/dists/stable/Release")).to be_false
    expect(AptLarder.immutable?("mirror/dists/stable/main/binary-amd64/Packages.xz")).to be_false
  end
end

Spectator.describe "AptLarder.format_bytes" do
  it "switches unit at each power of 1024" do
    expect(AptLarder.format_bytes(0_i64)).to eq("0 B")
    expect(AptLarder.format_bytes(1023_i64)).to eq("1023 B")
    expect(AptLarder.format_bytes(1024_i64)).to eq("1.0 KiB")
    expect(AptLarder.format_bytes(1_048_575_i64)).to eq("1024.0 KiB")
    expect(AptLarder.format_bytes(1_048_576_i64)).to eq("1.0 MiB")
    expect(AptLarder.format_bytes(1_073_741_824_i64)).to eq("1.0 GiB")
    expect(AptLarder.format_bytes(1_610_612_736_i64)).to eq("1.5 GiB")
  end
end
