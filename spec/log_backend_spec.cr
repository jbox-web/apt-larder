require "./spec_helper"
require "file_utils"

Spectator.describe AptLarder::LogBackend do
  let(tmp_dir) { spec_tmp_dir("log") }
  let(log_path) { File.join(tmp_dir, "apt-larder.log") }
  let(fallback) { IO::Memory.new }

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # A logger bound to *backend* through a builder of its own, so the examples
  # never touch the process-wide log configuration.
  private def logger_for(backend : Log::Backend) : Log
    builder = Log::Builder.new
    builder.bind("*", Log::Severity::Info, backend)
    builder.for("apt-larder.proxy")
  end

  # Messages written to the file at *path*, without timestamps.
  private def messages(path : String) : Array(String)
    File.read_lines(path).map(&.split(": ", 2).last)
  end

  it "writes each entry to the file before returning" do
    backend = AptLarder::LogBackend.new(File.open(log_path, "a"), fallback)
    logger_for(backend).info { "first line" }
    expect(messages(log_path)).to eq(["first line"])
  end

  # The destination can fail at any time: log partition full, stdout pipe
  # closed by a restarted collector. Logging must then neither raise into the
  # request that logs, nor block it.
  context "when the destination stops accepting writes" do
    it "does not raise into the caller" do
      file = File.open(log_path, "a")
      backend = AptLarder::LogBackend.new(file, fallback)
      file.close
      expect { logger_for(backend).info { "lost line" } }.not_to raise_error
    end

    it "never blocks, however many entries follow" do
      file = File.open(log_path, "a")
      backend = AptLarder::LogBackend.new(file, fallback)
      file.close
      log = logger_for(backend)
      done = Channel(Int32).new
      spawn do
        5000.times { log.info { "lost line" } }
        done.send(5000)
      end
      written = select
      when count = done.receive
        count
      when timeout(5.seconds)
        -1
      end
      expect(written).to eq(5000)
    end

    it "reports the failure once on the fallback stream, not once per entry" do
      file = File.open(log_path, "a")
      backend = AptLarder::LogBackend.new(file, fallback)
      file.close
      log = logger_for(backend)
      3.times { log.info { "lost line" } }
      expect(fallback.to_s.lines.size).to eq(1)
      expect(fallback.to_s).to start_with("apt-larder: cannot write to the log: ")
    end
  end

  describe "#reopen" do
    it "switches to a new file at the same path after a rotation" do
      backend = AptLarder::LogBackend.new(File.open(log_path, "a"), fallback)
      log = logger_for(backend)
      log.info { "before rotation" }
      File.rename(log_path, "#{log_path}.1")

      expect(backend.reopen(log_path)).to be_true
      log.info { "after rotation" }

      expect(messages("#{log_path}.1")).to eq(["before rotation"])
      expect(messages(log_path)).to eq(["after rotation"])
    end

    it "closes the previous file" do
      file = File.open(log_path, "a")
      backend = AptLarder::LogBackend.new(file, fallback)
      backend.reopen(log_path)
      expect(file.closed?).to be_true
    end

    # The old descriptor must stay in use: closing it first would leave every
    # later entry with nowhere to go.
    it "keeps writing to the current file when the new one cannot be opened" do
      file = File.open(log_path, "a")
      backend = AptLarder::LogBackend.new(file, fallback)
      log = logger_for(backend)

      expect(backend.reopen(File.join(tmp_dir, "missing-dir", "apt-larder.log"))).to be_false
      log.info { "still here" }

      expect(file.closed?).to be_false
      expect(messages(log_path)).to eq(["still here"])
      expect(fallback.to_s).to start_with("apt-larder: cannot reopen the log file: ")
    end
  end
end

Spectator.describe "AptLarder.bind_log" do
  private def bound(severity : Log::Severity) : {Log::Builder, Log::MemoryBackend}
    builder = Log::Builder.new
    backend = Log::MemoryBackend.new
    AptLarder.bind_log(builder, severity, backend)
    {builder, backend}
  end

  it "logs the application sources at the configured level" do
    builder, backend = bound(Log::Severity::Info)
    builder.for("apt-larder.proxy").info { "access line" }
    builder.for("apt-larder").debug { "too verbose" }
    expect(backend.entries.map(&.message)).to eq(["access line"])
  end

  # HTTP::Server reports a handler that raised on the "http.server" source:
  # unbound, a 500 leaves no trace anywhere.
  it "logs warnings and errors of every other source" do
    builder, backend = bound(Log::Severity::Info)
    builder.for("http.server").error { "Unhandled exception on HTTP::Handler" }
    builder.for("http.server").info { "noise" }
    expect(backend.entries.map(&.message)).to eq(["Unhandled exception on HTTP::Handler"])
  end

  it "writes an application entry once, not once per binding" do
    builder, backend = bound(Log::Severity::Info)
    builder.for("apt-larder.proxy").error { "one" }
    expect(backend.entries.size).to eq(1)
  end

  it "does not lower a stricter configured level for the other sources" do
    builder, backend = bound(Log::Severity::Error)
    builder.for("http.server").warn { "below the configured level" }
    builder.for("http.server").error { "kept" }
    expect(backend.entries.map(&.message)).to eq(["kept"])
  end
end

Spectator.describe "AptLarder.read_config" do
  let(tmp_dir) { spec_tmp_dir("startup") }
  let(no_env) { {} of String => String }

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  it "loads the file it is given" do
    path = File.join(tmp_dir, "custom.yml")
    File.write(path, "index_ttl: 42")
    expect(AptLarder.read_config(path, no_env).index_ttl).to eq(42)
  end

  # A path given on the command line that does not exist is a typo or a
  # missing mount: running on defaults instead would put the cache elsewhere.
  it "raises when the file it is given does not exist" do
    path = File.join(tmp_dir, "typo.yml")
    expect { AptLarder.read_config(path, no_env) }
      .to raise_error(ArgumentError, "config file not found: #{path}")
  end

  it "falls back to the defaults when no path is given and apt-larder.yml is absent" do
    Dir.cd(tmp_dir) do
      config = AptLarder.read_config(nil, no_env)
      expect(config.index_ttl).to eq(5)
      expect(config.cache_dir).to eq("./cache")
    end
  end

  it "loads apt-larder.yml from the working directory when no path is given" do
    File.write(File.join(tmp_dir, "apt-larder.yml"), "index_ttl: 7")
    Dir.cd(tmp_dir) do
      expect(AptLarder.read_config(nil, no_env).index_ttl).to eq(7)
    end
  end

  it "applies the environment over the file" do
    path = File.join(tmp_dir, "custom.yml")
    File.write(path, "index_ttl: 42")
    expect(AptLarder.read_config(path, {"APT_LARDER_INDEX_TTL" => "9"}).index_ttl).to eq(9)
  end

  it "rejects an invalid configuration" do
    path = File.join(tmp_dir, "custom.yml")
    File.write(path, "index_ttl: -1")
    expect { AptLarder.read_config(path, no_env) }.to raise_error(ArgumentError, /index_ttl/)
  end
end
