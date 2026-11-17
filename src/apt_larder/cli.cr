module AptLarder
  # Shared error handling for admin CLI subcommands.
  # Include in any `Admiral::Command` subclass that calls the admin API.
  module CLIErrorHandling
    private def handle_error(ex : Exception) : NoReturn
      STDERR.puts "Error: #{ex.message}"
      exit 1
    end
  end

  # Command-line interface built with Admiral.
  #
  # ## Subcommands
  #
  # - `server` — start the caching proxy
  # - `info`   — print version and Crystal build information
  # - `healthcheck` — probe the proxy, for Docker's `HEALTHCHECK`
  # - `stats`  — show live proxy counters via the admin API
  # - `cache`  — manage the cache via the admin API (list / flush / invalidate)
  # - `evict`  — trigger LRU / time-based eviction via the admin API
  #
  # ## Usage
  #
  # ```
  # apt-larder server --config /etc/apt-larder/apt-larder.yml
  # apt-larder healthcheck
  # apt-larder stats
  # apt-larder cache list --prefix deb.debian.org
  # apt-larder cache list --all --search php --sort size --order desc
  # apt-larder cache invalidate "deb.debian.org/debian/pool/main/pkg.deb"
  # apt-larder cache flush
  # apt-larder evict --max-age-days 7
  # ```
  class CLI < Admiral::Command
    # Starts the APT caching proxy.
    #
    # Loads configuration from the file given by `--config` (which must then
    # exist), or from `apt-larder.yml` in the working directory when there is
    # one, sets up logging, then runs the `Server` until `SIGTERM` is received.
    #
    # Signal handling:
    # - `SIGUSR1` — reopen the log file (use after log rotation)
    # - `SIGTERM` — stop accepting connections and drain in-flight requests
    class Server < Admiral::Command
      define_help description: "Run AptLarder webserver"

      # ameba:disable Lint/UselessAssign
      define_flag config : String,
        description: "Path to config file (default: apt-larder.yml in the working directory, if present)",
        long: "config",
        short: "c",
        default: ""

      def run
        AptLarder.init_app!(config_path(flags.config))

        server = AptLarder::Server.new(AptLarder.config)

        Signal::USR1.trap { AptLarder.reopen_log_file! }
        Signal::TERM.trap { server.stop }

        server.start
      ensure
        # Closing the log here guarantees that server.start has returned
        # and all in-flight requests are done before we flush and close.
        AptLarder.close_log_file!
      end
    end

    # Prints version and Crystal build information.
    class Info < Admiral::Command
      define_help description: "Show AptLarder information"

      def run
        puts "version: #{AptLarder.version}"
        puts
        puts "crystal:"
        puts Crystal::DESCRIPTION
        puts
      end
    end

    # Probes the proxy and exits 0 (healthy) or 1 (unhealthy).
    #
    # Exists for the distroless release image, which carries no shell and no
    # curl: see `AptLarder::Healthcheck` for why the probe has to live in the
    # binary itself, and why it targets the proxy rather than the admin API.
    class Healthcheck < Admiral::Command
      include CLIErrorHandling
      define_help description: "Probe the proxy and exit 0 (healthy) or 1 (unhealthy)"

      # ameba:disable Lint/UselessAssign
      define_flag config : String,
        description: "Path to config file (default: apt-larder.yml in the working directory, if present)",
        long: "config",
        short: "c",
        default: ""

      def run
        AptLarder.load_config!(config_path(flags.config))
        exit AptLarder::Healthcheck.run(AptLarder.config)
      rescue ex : Exception
        # Only an unreadable or invalid config file reaches this: the probe
        # itself never raises, it returns an exit code.
        handle_error(ex)
      end
    end

    # Prints live proxy counters from the admin API.
    class Stats < Admiral::Command
      include CLIErrorHandling
      define_help description: "Show proxy statistics (requires admin server)"

      # ameba:disable Lint/UselessAssign
      define_flag config : String,
        description: "Path to config file (default: apt-larder.yml in the working directory, if present)",
        long: "config",
        short: "c",
        default: ""

      def run
        client = build_client
        s = client.stats
        total = s["hits"].as_i64 + s["misses"].as_i64
        rate = total > 0 ? (s["hits"].as_i64 * 100.0 / total).round(1) : 0.0
        puts "Hits:           #{s["hits"].as_i64.format} (#{rate}%)"
        puts "Misses:         #{s["misses"].as_i64.format}"
        puts "Revalidations:  #{s["revalidations"].as_i64.format}"
        puts "Errors:         #{s["errors"].as_i64.format}"
        puts "Tunnels:        #{s["tunnels"].as_i64.format}"
        puts "Bytes served:   #{format_bytes(s["bytes"].as_i64)}"
        puts "Cache size:     #{format_bytes(s["cache_bytes"].as_i64)}"
      rescue ex : Exception
        handle_error(ex)
      end

      private def build_client
        AptLarder.load_config!(config_path(flags.config))
        Admin::Client.new(AptLarder.config.admin)
      end
    end

    # Cache management subcommands.
    class Cache < Admiral::Command
      define_help description: "Manage the cache via the admin API"

      class List < Admiral::Command
        include CLIErrorHandling
        define_help description: "List cached entries"

        # ameba:disable Lint/UselessAssign
        define_flag config : String, long: "config", short: "c", default: "",
          description: "Path to config file (default: apt-larder.yml in the working directory, if present)"
        # ameba:disable Lint/UselessAssign
        define_flag prefix : String, long: "prefix", short: "p", default: "",
          description: "Filter by URL prefix"
        # ameba:disable Lint/UselessAssign
        define_flag page : Int32, long: "page", default: 1_i32,
          description: "Page number"
        define_flag per_page : Int32, long: "per-page", default: 50_i32,
          description: "Entries per page"
        # ameba:disable Lint/UselessAssign
        define_flag all : Bool, long: "all", default: false,
          description: "Fetch all entries (overrides --page and --per-page)"
        # ameba:disable Lint/UselessAssign
        define_flag search : String, long: "search", short: "s", default: "",
          description: "Filter by case-insensitive substring of the key"
        define_flag sort : String, long: "sort", default: "key",
          description: "Sort column: key, size or mtime"
        # ameba:disable Lint/UselessAssign
        define_flag order : String, long: "order", default: "asc",
          description: "Sort order: asc or desc"

        def run
          AptLarder.load_config!(config_path(flags.config))
          client = Admin::Client.new(AptLarder.config.admin)
          sort = AptLarder::Cache::EntrySort.parse?(flags.sort) ||
                 raise ArgumentError.new("invalid --sort '#{flags.sort}' (expected key, size or mtime)")
          unless flags.order.in?("asc", "desc")
            raise ArgumentError.new("invalid --order '#{flags.order}' (expected asc or desc)")
          end
          descending = flags.order == "desc"
          if flags.all
            listing = client.cache_list_all(prefix: flags.prefix, search: flags.search,
              sort: sort, descending: descending)
            total = listing[:total]
            entries = listing[:entries]
            puts "#{total} entries"
          else
            result = client.cache_list(prefix: flags.prefix, page: flags.page, per_page: flags.per_page,
              search: flags.search, sort: sort, descending: descending)
            total = result["total"].as_i
            entries = result["entries"].as_a
            # The server caps per_page: count the pages with the size it applied.
            per_page = result["per_page"].as_i
            pages = {(total + per_page - 1) // per_page, 1}.max
            puts "#{total} entries  (page #{flags.page}/#{pages})"
          end
          puts
          table = Tallboy.table do
            columns do
              add "size", width: 10, align: :right
              add "date", width: 12
              add "type", width: 9
              add "key"
            end
            header
            entries.each do |entry|
              row [
                format_bytes(entry["size"].as_i64),
                entry["mtime"].as_s[0, 10],
                entry["immutable"].as_bool ? "immutable" : "index",
                entry["key"].as_s,
              ]
            end
          end
          puts table
        rescue ex : Exception
          handle_error(ex)
        end
      end

      class Flush < Admiral::Command
        include CLIErrorHandling
        define_help description: "Flush the entire cache"

        # ameba:disable Lint/UselessAssign
        define_flag config : String, long: "config", short: "c", default: "",
          description: "Path to config file (default: apt-larder.yml in the working directory, if present)"

        def run
          AptLarder.load_config!(config_path(flags.config))
          client = Admin::Client.new(AptLarder.config.admin)
          result = client.cache_flush
          puts "Flushed #{result["deleted"].as_i} entries."
        rescue ex : Exception
          handle_error(ex)
        end
      end

      class Invalidate < Admiral::Command
        include CLIErrorHandling
        define_help description: "Invalidate a single cache entry"

        # ameba:disable Lint/UselessAssign
        define_flag config : String, long: "config", short: "c", default: "",
          description: "Path to config file (default: apt-larder.yml in the working directory, if present)"
        # ameba:disable Lint/UselessAssign
        define_argument key : String, description: "Cache key to invalidate", required: true

        def run
          AptLarder.load_config!(config_path(flags.config))
          client = Admin::Client.new(AptLarder.config.admin)
          client.cache_invalidate(arguments.key)
          puts "Invalidated #{arguments.key}"
        rescue ex : Exception
          handle_error(ex)
        end
      end

      register_sub_command list, List, description: "List cached entries"
      register_sub_command flush, Flush, description: "Flush the entire cache"
      register_sub_command invalidate, Invalidate, description: "Invalidate one entry"

      define_help description: "Manage the cache"

      def run
        puts help
      end
    end

    # Triggers cache eviction via the admin API.
    class Evict < Admiral::Command
      include CLIErrorHandling
      define_help description: "Run eviction now via the admin API"

      # ameba:disable Lint/UselessAssign
      define_flag config : String, long: "config", short: "c", default: "",
        description: "Path to config file (default: apt-larder.yml in the working directory, if present)"
      # ameba:disable Lint/UselessAssign
      define_flag max_age_days : Int32, long: "max-age-days", default: 0_i32,
        description: "Evict files not accessed for N days (default: evict_after_days; nothing is evicted when that is 0 too)"

      def run
        AptLarder.load_config!(config_path(flags.config))
        client = Admin::Client.new(AptLarder.config.admin)
        if flags.max_age_days < 0
          raise ArgumentError.new("invalid --max-age-days #{flags.max_age_days} (expected a positive number of days)")
        end
        days = flags.max_age_days > 0 ? flags.max_age_days : nil
        if days.nil? && AptLarder.config.evict_after_days == 0
          puts "Time-based eviction is disabled (evict_after_days: 0): pass --max-age-days N to evict now."
          return
        end
        result = client.evict(days)
        freed = format_bytes(result["freed_bytes"].as_i64)
        puts "Evicted #{result["deleted"].as_i} files (freed #{freed})."
      rescue ex : Exception
        handle_error(ex)
      end
    end

    define_version AptLarder.version
    define_help description: "AptLarder"

    register_sub_command server, Server, description: "Run AptLarder webserver"
    register_sub_command info, Info, description: "Show AptLarder information"
    register_sub_command healthcheck, Healthcheck, description: "Probe the proxy liveness endpoint"
    register_sub_command stats, Stats, description: "Show proxy statistics"
    register_sub_command cache, Cache, description: "Manage the cache"
    register_sub_command evict, Evict, description: "Run eviction now"

    def run
      puts help
    end
  end
end

private def format_bytes(n : Int64) : String
  AptLarder.format_bytes(n)
end

# Value of a `--config` flag as `init_app!` / `load_config!` expect it: `nil`
# when the flag was not given, so that only an explicit path has to exist.
private def config_path(flag : String) : String?
  flag.empty? ? nil : flag
end
