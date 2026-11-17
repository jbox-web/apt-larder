require "./spec_helper"

Spectator.describe AptLarder::Licenses do
  # The list follows licenses.manifest: the LICENSE of each runtime shard, the
  # upstream text of each C library whose license carries a copyright line of
  # its own, one grouped file per SPDX id for the others, plus the project's
  # own LICENSE. An empty or partial list means the harvest did not run before
  # compilation.
  it "embeds the notices of the manifest plus the project license" do
    expect(AptLarder::Licenses::FILES.keys).to eq([
      "admiral.txt",
      "apt-larder.txt",
      "clib-Apache-2.0.txt",
      "clib-Boehm-GC.txt",
      "clib-GCC-runtime-exception.txt",
      "crystal-env.txt",
      "libyaml.txt",
      "musl.txt",
      "pcre2.txt",
      "tallboy.txt",
      "zlib.txt",
    ])
  end

  it "records which libraries each grouped notice covers" do
    expect(AptLarder::Licenses::FILES["clib-Apache-2.0.txt"]).to start_with("Used by: openssl, crystal\n")
  end

  # The GCC Runtime Library Exception 3.1 is an additional permission of the
  # GPLv3: libgcc is GPL-3.0-or-later WITH that exception, never GPL-2.0.
  it "names the license the GCC runtime exception applies to" do
    notice = AptLarder::Licenses::FILES["clib-GCC-runtime-exception.txt"]
    expect(notice).to contain("libgcc is distributed under GPL-3.0-or-later WITH the following exception")
    expect(notice).not_to contain("GPL-2.0")
  end

  # MIT, BSD and zlib all require the copyright notice to be reproduced: the
  # notice of the library, not the blank of a license template.
  it "carries the copyright notice of each library, as its authors wrote it" do
    files = AptLarder::Licenses::FILES
    expect(files["admiral.txt"]).to contain("Copyright (c) 2017 Jason Waldrip")
    expect(files["crystal-env.txt"]).to contain("Copyright (c) 2017 Brian J. Cardiff")
    expect(files["tallboy.txt"]).to contain("Copyright (c) 2019 Daniel Tsui")
    expect(files["libyaml.txt"]).to contain("Copyright (c) 2006-2016 Kirill Simonov")
    expect(files["musl.txt"]).to contain("Copyright © 2005-2020 Rich Felker, et al.")
    expect(files["pcre2.txt"]).to contain("University of Cambridge")
    expect(files["zlib.txt"]).to contain("Jean-loup Gailly and Mark Adler")
  end

  it "embeds no license template with its blanks left in" do
    AptLarder::Licenses::FILES.each_value do |text|
      expect(text).not_to match(/<year>|<owner>|<copyright holders>/)
    end
  end

  # What `apt-larder licenses` prints: every notice, each under a header that
  # names its file, separated by a blank line.
  describe ".text" do
    it "prints each notice under a header naming its file, in order" do
      text = AptLarder::Licenses.text
      expect(text).to start_with("==> admiral.txt <==\nMIT License\n")
      expect(text).to contain("\n\n==> apt-larder.txt <==\n")
      expect(text.scan(/^==> [^\n]+ <==$/m).map(&.[0])).to eq([
        "==> admiral.txt <==",
        "==> apt-larder.txt <==",
        "==> clib-Apache-2.0.txt <==",
        "==> clib-Boehm-GC.txt <==",
        "==> clib-GCC-runtime-exception.txt <==",
        "==> crystal-env.txt <==",
        "==> libyaml.txt <==",
        "==> musl.txt <==",
        "==> pcre2.txt <==",
        "==> tallboy.txt <==",
        "==> zlib.txt <==",
      ])
    end
  end
end
