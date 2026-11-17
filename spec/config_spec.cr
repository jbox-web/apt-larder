require "./spec_helper"

Spectator.describe AptLarder::Config do
  describe ".from_yaml" do
    it "applies defaults when YAML is empty" do
      config = AptLarder::Config.from_yaml("")
      expect(config.cache_dir).to eq("./cache")
      expect(config.index_ttl).to eq(5)
      expect(config.max_redirects).to eq(5)
      expect(config.connect_timeout).to eq(10)
      expect(config.read_timeout).to eq(30)
      expect(config.log_file).to eq("stdout")
      expect(config.log_level).to eq("info")
      expect(config.quiet?).to be_false
      expect(config.evict_after_days).to eq(0)
      expect(config.max_cache_size_gb).to eq(0.0)
      expect(config.remaps).to be_empty
      expect(config.server_host).to eq("0.0.0.0")
      expect(config.server_port).to eq(3142)
      expect(config.allow_local_targets?).to be_false
      expect(config.connect_ports).to eq([443])
    end

    it "parses the target policy fields" do
      config = AptLarder::Config.from_yaml("allow_local_targets: true\nconnect_ports: [443, 8443]")
      expect(config.allow_local_targets?).to be_true
      expect(config.connect_ports).to eq([443, 8443])
    end

    it "accepts an empty connect_ports list (CONNECT disabled)" do
      config = AptLarder::Config.from_yaml("connect_ports: []")
      expect(config.connect_ports).to be_empty
      expect { config.validate! }.not_to raise_error
    end

    # YAML reads a bare `50` as an integer, which a Float64 property rejects
    # without the converter.
    it "accepts an integer for max_cache_size_gb" do
      config = AptLarder::Config.from_yaml("max_cache_size_gb: 50")
      expect(config.max_cache_size_gb).to eq(50.0)
    end

    it "overrides specified fields without affecting others" do
      config = AptLarder::Config.from_yaml("index_ttl: 15\nserver_port: 8080")
      expect(config.index_ttl).to eq(15)
      expect(config.server_port).to eq(8080)
      expect(config.cache_dir).to eq("./cache")
      expect(config.max_redirects).to eq(5)
    end

    it "parses all fields" do
      config = AptLarder::Config.from_yaml(<<-YAML)
        cache_dir: /var/cache
        index_ttl: 10
        max_redirects: 3
        connect_timeout: 5
        read_timeout: 60
        log_file: /var/log/apt-larder.log
        log_level: debug
        quiet: true
        evict_after_days: 30
        max_cache_size_gb: 50.5
        server_host: 127.0.0.1
        server_port: 9000
        remaps:
          deb.debian.org: my-mirror.lan
        YAML
      expect(config.cache_dir).to eq("/var/cache")
      expect(config.index_ttl).to eq(10)
      expect(config.max_redirects).to eq(3)
      expect(config.connect_timeout).to eq(5)
      expect(config.read_timeout).to eq(60)
      expect(config.log_file).to eq("/var/log/apt-larder.log")
      expect(config.log_level).to eq("debug")
      expect(config.quiet?).to be_true
      expect(config.evict_after_days).to eq(30)
      expect(config.max_cache_size_gb).to eq(50.5)
      expect(config.server_host).to eq("127.0.0.1")
      expect(config.server_port).to eq(9000)
      expect(config.remaps["deb.debian.org"]).to eq("my-mirror.lan")
    end

    it "applies admin defaults when admin: key is absent" do
      config = AptLarder::Config.from_yaml("")
      expect(config.admin.enabled?).to be_false
      expect(config.admin.host).to eq("127.0.0.1")
      expect(config.admin.port).to eq(8080)
      expect(config.admin.api_token).to eq("")
      expect(config.admin.ui_user).to eq("")
      expect(config.admin.ui_password).to eq("")
    end

    it "parses nested admin config" do
      config = AptLarder::Config.from_yaml(<<-YAML)
        admin:
          enabled: true
          host: "0.0.0.0"
          port: 9090
          api_token: "secret"
          ui_user: "admin"
          ui_password: "pass"
        YAML
      expect(config.admin.enabled?).to be_true
      expect(config.admin.host).to eq("0.0.0.0")
      expect(config.admin.port).to eq(9090)
      expect(config.admin.api_token).to eq("secret")
      expect(config.admin.ui_user).to eq("admin")
      expect(config.admin.ui_password).to eq("pass")
    end
  end

  describe "#apply_env!" do
    it "overrides string fields" do
      config = AptLarder::Config.from_yaml("")
      config.apply_env!({"APT_LARDER_CACHE_DIR" => "/tmp/cache", "APT_LARDER_LOG_LEVEL" => "debug"})
      expect(config.cache_dir).to eq("/tmp/cache")
      expect(config.log_level).to eq("debug")
    end

    it "overrides integer fields" do
      config = AptLarder::Config.from_yaml("")
      config.apply_env!({"APT_LARDER_INDEX_TTL" => "15", "APT_LARDER_SERVER_PORT" => "8888"})
      expect(config.index_ttl).to eq(15)
      expect(config.server_port).to eq(8888)
    end

    it "overrides float fields" do
      config = AptLarder::Config.from_yaml("")
      config.apply_env!({"APT_LARDER_MAX_CACHE_SIZE_GB" => "20.5"})
      expect(config.max_cache_size_gb).to eq(20.5)
    end

    it "parses boolean fields (true/1/yes)" do
      config = AptLarder::Config.from_yaml("")
      config.apply_env!({"APT_LARDER_QUIET" => "true", "APT_LARDER_ADMIN_ENABLED" => "1"})
      expect(config.quiet?).to be_true
      expect(config.admin.enabled?).to be_true
    end

    it "takes precedence over file values" do
      config = AptLarder::Config.from_yaml("index_ttl: 5")
      config.apply_env!({"APT_LARDER_INDEX_TTL" => "99"})
      expect(config.index_ttl).to eq(99)
    end

    it "overrides nested admin fields" do
      config = AptLarder::Config.from_yaml("")
      config.apply_env!({"APT_LARDER_ADMIN_API_TOKEN" => "secret"})
      expect(config.admin.api_token).to eq("secret")
    end

    it "leaves fields unchanged when key is absent" do
      config = AptLarder::Config.from_yaml("index_ttl: 7")
      config.apply_env!({} of String => String)
      expect(config.index_ttl).to eq(7)
    end

    it "maps every variable to its own field" do
      config = AptLarder::Config.from_yaml("")
      config.apply_env!({
        "APT_LARDER_CACHE_DIR"           => "/srv/cache",
        "APT_LARDER_INDEX_TTL"           => "11",
        "APT_LARDER_MAX_REDIRECTS"       => "12",
        "APT_LARDER_CONNECT_TIMEOUT"     => "13",
        "APT_LARDER_READ_TIMEOUT"        => "14",
        "APT_LARDER_LOG_FILE"            => "/srv/log",
        "APT_LARDER_LOG_LEVEL"           => "warn",
        "APT_LARDER_QUIET"               => "yes",
        "APT_LARDER_EVICT_AFTER_DAYS"    => "15",
        "APT_LARDER_MAX_CACHE_SIZE_GB"   => "16.5",
        "APT_LARDER_SERVER_HOST"         => "192.0.2.1",
        "APT_LARDER_SERVER_PORT"         => "17",
        "APT_LARDER_ALLOW_LOCAL_TARGETS" => "YES",
        "APT_LARDER_CONNECT_PORTS"       => "443, 8443",
        "APT_LARDER_ADMIN_ENABLED"       => "true",
        "APT_LARDER_ADMIN_HOST"          => "192.0.2.2",
        "APT_LARDER_ADMIN_PORT"          => "18",
        "APT_LARDER_ADMIN_API_TOKEN"     => "tok",
        "APT_LARDER_ADMIN_UI_USER"       => "usr",
        "APT_LARDER_ADMIN_UI_PASSWORD"   => "pwd",
      })
      expect(config.cache_dir).to eq("/srv/cache")
      expect(config.index_ttl).to eq(11)
      expect(config.max_redirects).to eq(12)
      expect(config.connect_timeout).to eq(13)
      expect(config.read_timeout).to eq(14)
      expect(config.log_file).to eq("/srv/log")
      expect(config.log_level).to eq("warn")
      expect(config.quiet?).to be_true
      expect(config.evict_after_days).to eq(15)
      expect(config.max_cache_size_gb).to eq(16.5)
      expect(config.server_host).to eq("192.0.2.1")
      expect(config.server_port).to eq(17)
      expect(config.allow_local_targets?).to be_true
      expect(config.connect_ports).to eq([443, 8443])
      expect(config.admin.enabled?).to be_true
      expect(config.admin.host).to eq("192.0.2.2")
      expect(config.admin.port).to eq(18)
      expect(config.admin.api_token).to eq("tok")
      expect(config.admin.ui_user).to eq("usr")
      expect(config.admin.ui_password).to eq("pwd")
    end

    it "reads any other boolean value as false" do
      config = AptLarder::Config.from_yaml("quiet: true")
      config.apply_env!({"APT_LARDER_QUIET" => "no"})
      expect(config.quiet?).to be_false
    end

    it "names the variable when an integer does not parse" do
      config = AptLarder::Config.from_yaml("")
      expect { config.apply_env!({"APT_LARDER_INDEX_TTL" => "abc"}) }
        .to raise_error(ArgumentError, "APT_LARDER_INDEX_TTL must be an integer (got 'abc')")
    end

    it "names the variable when a number does not parse" do
      config = AptLarder::Config.from_yaml("")
      expect { config.apply_env!({"APT_LARDER_MAX_CACHE_SIZE_GB" => "big"}) }
        .to raise_error(ArgumentError, "APT_LARDER_MAX_CACHE_SIZE_GB must be a number (got 'big')")
    end

    it "names the variable when a port list does not parse" do
      config = AptLarder::Config.from_yaml("")
      expect { config.apply_env!({"APT_LARDER_CONNECT_PORTS" => "443,https"}) }
        .to raise_error(ArgumentError, "APT_LARDER_CONNECT_PORTS must be a comma-separated list of integers (got '443,https')")
    end
  end

  describe "#unknown_keys" do
    it "is empty for a config made of known keys" do
      config = AptLarder::Config.from_yaml("index_ttl: 5\nadmin:\n  enabled: false")
      expect(config.unknown_keys).to be_empty
    end

    it "lists misspelt keys, nested ones under their section" do
      config = AptLarder::Config.from_yaml("evict_after_day: 30\nadmin:\n  enabeld: true")
      expect(config.unknown_keys).to eq(["evict_after_day", "admin.enabeld"])
    end
  end

  describe "#validate!" do
    it "passes on a default config" do
      expect { AptLarder::Config.from_yaml("").validate! }.not_to raise_error
    end

    it "raises on invalid server_port" do
      config = AptLarder::Config.from_yaml("server_port: 0")
      expect { config.validate! }.to raise_error(ArgumentError, /server_port/)
    end

    it "raises on negative index_ttl" do
      config = AptLarder::Config.from_yaml("index_ttl: -1")
      expect { config.validate! }.to raise_error(ArgumentError, /index_ttl/)
    end

    it "raises on zero connect_timeout" do
      config = AptLarder::Config.from_yaml("connect_timeout: 0")
      expect { config.validate! }.to raise_error(ArgumentError, /connect_timeout/)
    end

    it "raises on negative evict_after_days" do
      config = AptLarder::Config.from_yaml("evict_after_days: -1")
      expect { config.validate! }.to raise_error(ArgumentError, /evict_after_days/)
    end

    it "raises on negative max_cache_size_gb" do
      config = AptLarder::Config.from_yaml("max_cache_size_gb: -0.1")
      expect { config.validate! }.to raise_error(ArgumentError, /max_cache_size_gb/)
    end

    it "raises on invalid log_level" do
      config = AptLarder::Config.from_yaml("log_level: nonsense")
      expect { config.validate! }.to raise_error(ArgumentError, /log_level/)
    end

    it "raises on invalid admin port when admin is enabled" do
      config = AptLarder::Config.from_yaml("admin:\n  enabled: true\n  port: 99999")
      expect { config.validate! }.to raise_error(ArgumentError, /admin\.port/)
    end

    it "ignores invalid admin port when admin is disabled" do
      config = AptLarder::Config.from_yaml("admin:\n  enabled: false\n  port: 99999")
      expect { config.validate! }.not_to raise_error
    end

    it "raises on negative max_redirects" do
      config = AptLarder::Config.from_yaml("max_redirects: -1")
      expect { config.validate! }.to raise_error(ArgumentError, /max_redirects/)
    end

    it "raises on zero read_timeout" do
      config = AptLarder::Config.from_yaml("read_timeout: 0")
      expect { config.validate! }.to raise_error(ArgumentError, /read_timeout/)
    end

    it "raises on an empty cache_dir" do
      config = AptLarder::Config.from_yaml(%(cache_dir: ""))
      expect { config.validate! }.to raise_error(ArgumentError, /cache_dir/)
    end

    it "raises on a server_port above 65535" do
      config = AptLarder::Config.from_yaml("server_port: 65536")
      expect { config.validate! }.to raise_error(ArgumentError, /server_port/)
    end

    it "raises on a CONNECT port outside 1-65535" do
      config = AptLarder::Config.from_yaml("connect_ports: [443, 70000]")
      expect { config.validate! }.to raise_error(ArgumentError, /connect_ports/)
    end

    it "raises when only one of the UI credentials is set" do
      config = AptLarder::Config.from_yaml(%(admin:\n  ui_password: "secret"))
      expect { config.validate! }.to raise_error(ArgumentError, /ui_user and admin.ui_password must be set together/)
      config = AptLarder::Config.from_yaml(%(admin:\n  ui_user: "admin"))
      expect { config.validate! }.to raise_error(ArgumentError, /ui_user and admin.ui_password must be set together/)
    end

    context "admin server reachable from other hosts" do
      it "raises when no authentication is configured" do
        config = AptLarder::Config.from_yaml(%(admin:\n  enabled: true\n  host: "0.0.0.0"))
        expect { config.validate! }.to raise_error(ArgumentError, /admin.host 0.0.0.0 is reachable from other hosts/)
      end

      it "passes with an API token" do
        config = AptLarder::Config.from_yaml(%(admin:\n  enabled: true\n  host: "0.0.0.0"\n  api_token: "tok"))
        expect { config.validate! }.not_to raise_error
      end

      it "passes with UI credentials" do
        config = AptLarder::Config.from_yaml(%(admin:\n  enabled: true\n  host: "192.0.2.7"\n  ui_user: "u"\n  ui_password: "p"))
        expect { config.validate! }.not_to raise_error
      end

      it "does not apply to a loopback bind" do
        ["127.0.0.1", "::1", "localhost"].each do |host|
          config = AptLarder::Config.from_yaml(%(admin:\n  enabled: true\n  host: "#{host}"))
          expect { config.validate! }.not_to raise_error
        end
      end

      it "does not apply while the admin server is disabled" do
        config = AptLarder::Config.from_yaml(%(admin:\n  enabled: false\n  host: "0.0.0.0"))
        expect { config.validate! }.not_to raise_error
      end
    end

    it "collects multiple errors in one message" do
      config = AptLarder::Config.from_yaml("server_port: 0\nconnect_timeout: 0")
      expect { config.validate! }.to raise_error(ArgumentError, /server_port.*connect_timeout|connect_timeout.*server_port/)
    end
  end
end
