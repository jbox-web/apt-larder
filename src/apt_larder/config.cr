module AptLarder
  # Top-level configuration loaded from a YAML file (default: `apt-larder.yml`).
  #
  # All fields have sensible defaults so a minimal config only needs to override
  # what differs from the defaults. Unknown keys are silently ignored.
  #
  # ## Example
  #
  # ```yaml
  # cache_dir: /var/cache/apt-larder
  # index_ttl: 5
  # max_redirects: 5
  # connect_timeout: 10
  # read_timeout: 30
  # log_file: /var/log/apt-larder.log
  # quiet: false
  # evict_after_days: 30
  # server_host: "0.0.0.0"
  # server_port: 3142
  # admin:
  #   enabled: false
  # ```
  #
  # See `AdminConfig` for the nested `admin:` section.
  class Config
    include YAML::Serializable

    # Accepts both YAML integers (`0`) and floats (`0.5`) for Float64 fields.
    # YAML parses bare `0` as an integer, which Crystal's YAML::Serializable
    # rejects for Float64 properties without this converter.
    module Float64Converter
      def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : Float64
        node.as(YAML::Nodes::Scalar).value.to_f64
      rescue
        raise YAML::ParseException.new("Expected Float64-compatible value", 0, 0)
      end
    end

    # Directory where cached packages and index files are stored on disk.
    property cache_dir : String = "./cache"

    # Minutes before a cached index file (`Release`, `Packages`, …) is
    # considered stale and revalidated against the upstream with a conditional
    # GET (`If-Modified-Since`).
    #
    # Immutable files (`.deb`, paths containing `/pool/` or `/by-hash/`) are
    # never subject to this TTL — they are cached forever.
    property index_ttl : Int32 = 5

    # Maximum number of HTTP redirects to follow for a single upstream request.
    #
    # Mirrors commonly redirect `http://` to `https://`; this limit prevents
    # infinite redirect loops.
    property max_redirects : Int32 = 5

    # Upstream TCP connect timeout in seconds.
    property connect_timeout : Int32 = 10

    # Upstream read timeout in seconds.
    #
    # Applies to each individual read on the upstream connection, not to the
    # total download duration. Increase for slow mirrors or very large files.
    property read_timeout : Int32 = 30

    # Destination for access logs.
    #
    # Use `"stdout"` to write to standard output, or an absolute path to write
    # to a file. Send `SIGUSR1` to reopen the file after log rotation.
    property log_file : String = "stdout"

    # Minimum log severity. Accepted values (case-insensitive):
    # `trace`, `debug`, `info`, `warn`, `error`, `fatal`, `off`.
    #
    # Defaults to `info`. Use `debug` to log upstream fetches and redirects.
    property log_level : String = "info"

    # When `true`, only `MISS` and `ERR` lines are logged.
    #
    # `HIT` and `REVAL` lines are suppressed, which significantly reduces log
    # volume on a warm cache where the vast majority of requests are hits.
    property? quiet : Bool = false

    # Delete cached files not accessed for this many days.
    #
    # The eviction loop runs once per hour in the background. Set to `0`
    # (default) to disable automatic eviction entirely.
    property evict_after_days : Int32 = 0

    # Maximum cache size in gigabytes. When exceeded, the oldest files are
    # deleted (LRU) until the cache fits within the limit. Set to `0` to
    # disable size-based eviction entirely.
    #
    # Accepts both integer (`0`) and float (`0.5`) in YAML.
    @[YAML::Field(converter: AptLarder::Config::Float64Converter)]
    property max_cache_size_gb : Float64 = 0.0

    # Host remapping table.
    #
    # Maps upstream hostnames to replacement targets. The cache key always uses
    # the original hostname so the cache remains valid if the mirror changes.
    #
    # Each value can be a bare hostname (`my-mirror.lan`), a `host:port` pair,
    # or a full URL (`http://my-mirror.lan:8080`). The path is preserved.
    #
    # ```yaml
    # remaps:
    #   deb.debian.org: my-mirror.internal
    #   security.debian.org: my-mirror.internal
    # ```
    property remaps : Hash(String, String) = {} of String => String

    # IP address the proxy server binds to.
    property server_host : String = "0.0.0.0"

    # TCP port the proxy server listens on.
    property server_port : Int32 = 3142

    # Configuration for the optional admin server (REST API + web UI).
    #
    # See `AdminConfig` for available fields.
    @[YAML::Field(key: "admin")]
    property admin : AdminConfig = AdminConfig.from_yaml("")

    # Overrides config values from *env*.
    #
    # Convention: `APT_LARDER_<FIELD>` for top-level fields,
    # `APT_LARDER_ADMIN_<FIELD>` for nested admin fields.
    # Boolean fields accept `"true"`, `"1"`, `"yes"` (case-insensitive) as truthy.
    #
    # Defaults to the process environment. Pass a plain `Hash` in tests to
    # avoid mutating `ENV` (which is not thread-safe on UNIX — see crystal#16449).
    #
    # Call after `from_yaml` and before `validate!`.
    def apply_env!(env : Hash(String, String) = ENV.to_h) : Nil
      env["APT_LARDER_CACHE_DIR"]?.try { |v| @cache_dir = v }
      env["APT_LARDER_INDEX_TTL"]?.try { |v| @index_ttl = v.to_i }
      env["APT_LARDER_MAX_REDIRECTS"]?.try { |v| @max_redirects = v.to_i }
      env["APT_LARDER_CONNECT_TIMEOUT"]?.try { |v| @connect_timeout = v.to_i }
      env["APT_LARDER_READ_TIMEOUT"]?.try { |v| @read_timeout = v.to_i }
      env["APT_LARDER_LOG_FILE"]?.try { |v| @log_file = v }
      env["APT_LARDER_LOG_LEVEL"]?.try { |v| @log_level = v }
      env["APT_LARDER_QUIET"]?.try { |v| @quiet = truthy?(v) }
      env["APT_LARDER_EVICT_AFTER_DAYS"]?.try { |v| @evict_after_days = v.to_i }
      env["APT_LARDER_MAX_CACHE_SIZE_GB"]?.try { |v| @max_cache_size_gb = v.to_f }
      env["APT_LARDER_SERVER_HOST"]?.try { |v| @server_host = v }
      env["APT_LARDER_SERVER_PORT"]?.try { |v| @server_port = v.to_i }
      env["APT_LARDER_ADMIN_ENABLED"]?.try { |v| @admin.enabled = truthy?(v) }
      env["APT_LARDER_ADMIN_HOST"]?.try { |v| @admin.host = v }
      env["APT_LARDER_ADMIN_PORT"]?.try { |v| @admin.port = v.to_i }
      env["APT_LARDER_ADMIN_API_TOKEN"]?.try { |v| @admin.api_token = v }
      env["APT_LARDER_ADMIN_UI_USER"]?.try { |v| @admin.ui_user = v }
      env["APT_LARDER_ADMIN_UI_PASSWORD"]?.try { |v| @admin.ui_password = v }
    end

    # Raises `ArgumentError` with a descriptive message if any field contains
    # an invalid value. Call once after loading the config file.
    def validate! : Nil
      errors = collect_errors
      raise ArgumentError.new(errors.join("; ")) unless errors.empty?
    end

    private def truthy?(value : String) : Bool
      value.downcase.in?("true", "1", "yes")
    end

    private def collect_errors : Array(String)
      errors = collect_numeric_errors
      errors << "cache_dir must not be empty" if cache_dir.empty?
      begin
        ::Log::Severity.parse(log_level)
      rescue ArgumentError
        errors << "log_level '#{log_level}' is invalid (trace/debug/info/warn/error/fatal/off)"
      end
      errors
    end

    private def collect_numeric_errors : Array(String)
      errors = [] of String
      errors << "server_port must be 1–65535 (got #{server_port})" unless server_port.in?(1..65535)
      errors << "admin.port must be 1–65535 (got #{admin.port})" if admin.enabled? && !admin.port.in?(1..65535)
      errors << "index_ttl must be >= 0 (got #{index_ttl})" if index_ttl < 0
      errors << "max_redirects must be >= 0 (got #{max_redirects})" if max_redirects < 0
      errors << "connect_timeout must be > 0 (got #{connect_timeout})" if connect_timeout <= 0
      errors << "read_timeout must be > 0 (got #{read_timeout})" if read_timeout <= 0
      errors << "evict_after_days must be >= 0 (got #{evict_after_days})" if evict_after_days < 0
      errors << "max_cache_size_gb must be >= 0 (got #{max_cache_size_gb})" if max_cache_size_gb < 0
      errors
    end
  end
end
