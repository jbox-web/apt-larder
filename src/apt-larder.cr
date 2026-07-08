# Load std libs
require "log"
require "json"
require "yaml"
require "digest/sha256"
require "http/server"
require "http/client"
require "uri"

# Load external libs
require "crystal-env/core"

require "admiral"
require "tallboy"

# :nodoc:
module Crystal
  # :nodoc:
  struct Env
  end
end

# Set environment
Crystal::Env.default("development")

# Load apt-larder
require "./apt_larder/*"
require "./apt_larder/admin/*"

# Top-level module — holds global config and logging state.
#
# Startup sequence (called from `CLI::Server#run`):
#   1. `init_app!(config_file)` — load YAML, apply env overrides, validate, open log
#   2. `Server.new(config).start` — bind, listen, run background loops
#
# Signal handlers update state here: `SIGUSR1` calls `reopen_log_file!`,
# `SIGTERM` calls `server.stop`.
module AptLarder
  Log = ::Log.for("apt-larder")

  # Serialises log-state mutation with teardown. `reopen_log_file!` runs on the
  # SIGUSR1 handler's own fiber, concurrently with the shutdown path's
  # `close_log_file!`; both touch `@@log_file`/`@@logger`. Mirrors the `@@mutex`
  # guard around systemd's `@@socket`. Boot-time `setup_log!` runs on the main
  # fiber before any spawn, so it needs no lock.
  @@log_mutex = Mutex.new

  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
  GIT_REF = {{ `git log -n 1 --format="%H" | head -c 8`.chomp.stringify }}

  # Returns `"<version> (<git-ref>)"`.
  def self.version
    "#{VERSION} (#{GIT_REF})"
  end

  # Bootstraps the application: load config → apply env vars → validate → open log.
  # Raises `ArgumentError` if the config is invalid.
  def self.init_app!(config_file)
    load_config(config_file)
    config.apply_env!
    config.validate!
    setup_log!
  end

  # Returns the active `Config`, constructing one with defaults if none has
  # been loaded yet.
  def self.config
    @@config ||= default_config
  end

  # Closes the log file if logging to a file (no-op when writing to stdout).
  # Called from `CLI::Server#run`'s ensure block after `Server#start` returns.
  def self.close_log_file!
    @@log_mutex.synchronize do
      @@log_file.try(&.close) unless log_to_stdout?
    end
  end

  # Reopens the log file after log rotation (`SIGUSR1`).
  def self.reopen_log_file!
    @@log_mutex.synchronize do
      # Close the old descriptor before dropping it — otherwise every rotation
      # leaks the previous file's fd. No-op when writing to stdout.
      @@log_file.try(&.close) unless log_to_stdout?
      # Both must be reset: @@log_file to open the new file, @@logger to
      # rebuild the backend pointing at it. Resetting only one leaves a
      # backend writing to the old, already-closed file descriptor.
      @@log_file = nil
      @@logger = nil
      setup_log!
    end
  end

  private def self.default_config
    Config.from_yaml("")
  end

  # Reads *config_path* (silently uses defaults if the file is absent) and
  # stores the parsed `Config`.
  private def self.load_config(config_path)
    config_file = load_config_file(config_path)
    self.config = Config.from_yaml(config_file)
  end

  private def self.load_config_file(file)
    file = File.expand_path(file)
    return "" unless File.exists?(file)

    File.read(file)
  end

  private def self.config=(config : Config)
    @@config = config
  end

  # Configures Crystal's `Log` using the severity from `config.log_level`.
  # Falls back to `:info` and logs a warning if the value is unrecognised.
  private def self.setup_log!
    severity = ::Log::Severity.parse(config.log_level)
    ::Log.setup do |builder|
      builder.bind "apt-larder.*", severity, logger
    end
  rescue ArgumentError
    ::Log.setup do |builder|
      builder.bind "*", :info, logger
    end
    Log.warn { "unknown log_level '#{config.log_level}', defaulting to info" }
  end

  # Returns the `Log::IOBackend` for the current log destination, creating it
  # on first call.
  private def self.logger
    @@logger ||= ::Log::IOBackend.new(log_file)
  end

  # Returns the log IO — `STDOUT` or the configured file path opened in append
  # mode. Memoised; reset by `reopen_log_file!`.
  private def self.log_file
    @@log_file ||= log_to_stdout? ? STDOUT : File.open(config.log_file, "a")
  end

  private def self.log_to_stdout?
    config.log_file.downcase == "stdout"
  end
end

# Start the CLI
unless Crystal.env.test?
  begin
    AptLarder::CLI.run
  rescue e : Exception
    puts e.message
    exit 1
  end
end
