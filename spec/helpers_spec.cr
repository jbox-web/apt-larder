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

  it "falls back to 443 for a non-numeric port" do
    expect(AptLarder.parse_connect_target("host:bogus")).to eq({"host", 443})
  end
end
