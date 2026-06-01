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

    it "collects multiple errors in one message" do
      config = AptLarder::Config.from_yaml("server_port: 0\nconnect_timeout: 0")
      expect { config.validate! }.to raise_error(ArgumentError, /server_port.*connect_timeout|connect_timeout.*server_port/)
    end
  end
end
