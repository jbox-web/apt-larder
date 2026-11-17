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
# The client subcommands (`stats`, `cache`, `evict`, `healthcheck`) only call
# `load_config!`: they have no business opening the server's log file.
#
# Signal handlers update state here: `SIGUSR1` calls `reopen_log_file!`,
# `SIGTERM` calls `server.stop`.
module AptLarder
  Log = ::Log.for("apt-larder")

  # Config file looked up in the working directory when none is given.
  DEFAULT_CONFIG_FILE = "apt-larder.yml"

  # Serialises log-state mutation with teardown. `reopen_log_file!` runs on the
  # SIGUSR1 handler's own fiber, concurrently with the shutdown path's
  # `close_log_file!`; both touch `@@logger`. Mirrors the `@@mutex` guard
  # around systemd's `@@socket`. Boot-time `setup_log!` runs on the main fiber
  # before any spawn, so it needs no lock.
  @@log_mutex = Mutex.new

  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
  GIT_REF = {{ `git log -n 1 --format="%H" | head -c 8`.chomp.stringify }}

  # Returns `"<version> (<git-ref>)"`.
  def self.version
    "#{VERSION} (#{GIT_REF})"
  end

  # Bootstraps the server: load config → apply env vars → validate → open log.
  # Raises `ArgumentError` if the config is invalid, or if *config_file* is
  # given and does not exist.
  def self.init_app!(config_file : String?)
    load_config!(config_file)
    setup_log!
    config.unknown_keys.each do |key|
      Log.warn { "unknown configuration key '#{key}' ignored — check its spelling" }
    end
    if config_file.nil? && !File.exists?(DEFAULT_CONFIG_FILE)
      Log.warn { "no #{DEFAULT_CONFIG_FILE} in #{Dir.current}: running on defaults (pass --config to name a file)" }
    end
  end

  # Loads, overrides from the environment and validates the configuration,
  # without touching the log. Same errors as `init_app!`.
  def self.load_config!(config_file : String?)
    self.config = read_config(config_file)
  end

  # Builds the `Config` for *config_file*, overridden by *env* and validated.
  #
  # A path given explicitly must exist: silently falling back to the defaults
  # would run the server with another cache directory, no admin server and
  # another log destination than the ones the operator asked for. With `nil`,
  # `DEFAULT_CONFIG_FILE` is used when present and the defaults otherwise — a
  # container started with no configuration at all is a supported setup.
  #
  # Raises `ArgumentError` on a missing explicit file or an invalid value.
  def self.read_config(config_file : String?, env : Hash(String, String) = ENV.to_h) : Config
    config = Config.from_yaml(read_config_file(config_file))
    config.apply_env!(env)
    config.validate!
    config
  end

  # Returns the active `Config`, constructing one with defaults if none has
  # been loaded yet.
  def self.config
    @@config ||= default_config
  end

  # Binds *backend* on *builder*: the application sources at *severity*, and
  # every other source (the standard library's `http.server`, which reports
  # handlers that raised) at warning level or stricter — an unhandled
  # exception answered with a 500 must leave a trace.
  #
  # The catch-all goes first: for a source matching both bindings of the same
  # backend, the level bound last is the one that applies.
  def self.bind_log(builder : ::Log::Configuration, severity : ::Log::Severity, backend : ::Log::Backend) : Nil
    builder.bind "*", {severity, ::Log::Severity::Warn}.max, backend
    builder.bind "apt-larder.*", severity, backend
  end

  # Closes the log file if logging to a file (no-op when writing to stdout).
  # Called from `CLI::Server#run`'s ensure block after `Server#start` returns.
  def self.close_log_file!
    @@log_mutex.synchronize do
      @@logger.try(&.close_io)
    end
  end

  # Reopens the log file after log rotation (`SIGUSR1`). When the file cannot
  # be reopened, logging carries on in the previous one and the failure is
  # reported there. No-op when writing to stdout.
  def self.reopen_log_file!
    @@log_mutex.synchronize do
      next if log_to_stdout?
      backend = @@logger
      next unless backend
      Log.error { "cannot reopen #{config.log_file}, still logging to the previous file" } unless backend.reopen(config.log_file)
    end
  end

  private def self.default_config
    Config.from_yaml("")
  end

  # Returns the YAML text for *config_file* — see `read_config` for what a
  # missing file means in each case.
  private def self.read_config_file(config_file : String?) : String
    if config_file
      path = File.expand_path(config_file)
      raise ArgumentError.new("config file not found: #{config_file}") unless File.exists?(path)
      return File.read(path)
    end
    File.exists?(DEFAULT_CONFIG_FILE) ? File.read(DEFAULT_CONFIG_FILE) : ""
  end

  private def self.config=(config : Config)
    @@config = config
  end

  # Configures Crystal's `Log` using the severity from `config.log_level`
  # (validated beforehand by `Config#validate!`).
  private def self.setup_log!
    severity = ::Log::Severity.parse(config.log_level)
    backend = logger
    ::Log.setup do |builder|
      bind_log(builder, severity, backend)
    end
  end

  # Returns the `LogBackend` for the configured log destination, creating it
  # on first call.
  private def self.logger : LogBackend
    @@logger ||= LogBackend.new(log_to_stdout? ? STDOUT : File.open(config.log_file, "a"))
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
    STDERR.puts "Error: #{e.message || e.class.name}"
    exit 1
  end
end
