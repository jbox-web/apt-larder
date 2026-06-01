module AptLarder
  # Configuration for the admin HTTP server.
  #
  # The admin server exposes a JSON REST API (`/api/*`) for programmatic cache
  # management and an optional web UI (`/*`) that consumes it. Both run on a
  # dedicated port, separate from the main proxy port.
  #
  # ## Authentication
  #
  # Two independent auth mechanisms are supported:
  #
  # - **API** (`/api/*`): HTTP Bearer token. Set `api_token` to a non-empty
  #   string; clients must send `Authorization: Bearer <token>`.
  # - **UI** (`/*`): HTTP Basic Auth. Set both `ui_user` and `ui_password`;
  #   browsers will prompt for credentials.
  #
  # Leaving a credential field empty disables auth for that path.
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

    # When `false` (default), the admin server is not started.
    property? enabled : Bool = false

    # IP address the admin server binds to.
    #
    # Defaults to loopback (`127.0.0.1`). Do not change to `0.0.0.0`
    # unless authentication is configured.
    property host : String = "127.0.0.1"

    # TCP port the admin server listens on.
    property port : Int32 = 8080

    # Bearer token required for all `/api/*` requests.
    #
    # Empty string disables authentication for the API (allow-all).
    property api_token : String = ""

    # Username for HTTP Basic Auth on the web UI (`/*`).
    #
    # Both `ui_user` and `ui_password` must be non-empty to enable auth.
    property ui_user : String = ""

    # Password for HTTP Basic Auth on the web UI (`/*`).
    property ui_password : String = ""
  end
end
