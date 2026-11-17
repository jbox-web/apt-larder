module AptLarder
  # Configuration for the admin HTTP server.
  #
  # The admin server exposes a JSON REST API (`/api/*`) for programmatic cache
  # management and an optional web UI (`/*`) that consumes it. Both run on a
  # dedicated port, separate from the main proxy port.
  #
  # ## Authentication
  #
  # Two credentials are supported:
  #
  # - **API token** (`api_token`): scripts and Prometheus send
  #   `Authorization: Bearer <token>` to `/api/*`.
  # - **UI credentials** (`ui_user` + `ui_password`, set together): HTTP Basic
  #   Auth. Browsers prompt for them on the web UI (`/*`), and the UI's own
  #   calls to `/api/*` are authenticated by the same credentials.
  #
  # As soon as either is configured, `/api/*` requires one of them. With
  # neither, the admin server is open — which `Config#validate!` only accepts
  # on a loopback `host`.
  # The admin server is disabled by default (`enabled: false`).
  #
  # ## Example config
  #
  # ```yaml
  # admin:
  #   enabled: true
  #   host: "127.0.0.1"
  #   port: 8080
  #   api_token: "change-me"
  #   ui_user: "admin"
  #   ui_password: "change-me"
  # ```
  class AdminConfig
    include YAML::Serializable
    include YAML::Serializable::Unmapped

    # When `false` (default), the admin server is not started.
    property? enabled : Bool = false

    # IP address the admin server binds to.
    #
    # Defaults to loopback (`127.0.0.1`). Any other address (`0.0.0.0` inside
    # Docker) requires authentication to be configured: the server refuses to
    # start otherwise.
    property host : String = "127.0.0.1"

    # TCP port the admin server listens on.
    property port : Int32 = 8080

    # Bearer token accepted on `/api/*` requests. Empty string: no token.
    property api_token : String = ""

    # Username for HTTP Basic Auth on the web UI (`/*`) and on the `/api/*`
    # calls it makes.
    #
    # `ui_user` and `ui_password` are set together or not at all.
    property ui_user : String = ""

    # Password for HTTP Basic Auth, see `ui_user`.
    property ui_password : String = ""

    # `true` when both UI credentials are set.
    def ui_auth? : Bool
      !ui_user.empty? && !ui_password.empty?
    end

    # `true` when at least one credential protects the API.
    def auth_configured? : Bool
      !api_token.empty? || ui_auth?
    end

    # `true` when `host` only answers on the machine itself: a loopback
    # address literal, or the name `localhost`. Anything else — a wildcard, a
    # LAN address, another name — is treated as reachable from other hosts.
    def loopback_host? : Bool
      name = host.strip.lchop('[').rchop(']')
      return true if name.compare("localhost", case_insensitive: true) == 0
      Socket::IPAddress.valid?(name) && Socket::IPAddress.new(name, 0).loopback?
    end
  end
end
