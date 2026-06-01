# extra/

Files for running apt-larder as a system service.

## apt-larder.service

systemd unit file. Uses `Type=notify` — systemd waits for `READY=1` before
considering the service started. Includes watchdog and basic hardening.

```sh
# Install
sudo install -Dm644 apt-larder.service /etc/systemd/system/apt-larder.service
sudo install -Dm640 apt-larder.yml.example /etc/apt-larder/apt-larder.yml

# Create service user (systemd manages the cache and log directories)
sudo useradd -r -s /usr/sbin/nologin apt-larder

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable --now apt-larder

# Status
sudo systemctl status apt-larder
```

## apt-larder.logrotate

logrotate configuration for daily log rotation with 14-day retention.
Install to `/etc/logrotate.d/apt-larder`:

```sh
sudo install -m644 apt-larder.logrotate /etc/logrotate.d/apt-larder
```

Sends `SIGUSR1` via systemd after rotation so apt-larder reopens the log file without restarting.

## grafana-dashboard.json

Grafana dashboard for the Prometheus metrics exposed at `/api/metrics`.

Import via **Dashboards → Import → Upload JSON file**, or via the API:

```sh
curl -X POST http://grafana:3000/api/dashboards/import \
  -H 'Content-Type: application/json' \
  -u admin:admin \
  -d "{\"dashboard\": $(cat grafana-dashboard.json), \"overwrite\": true, \"folderId\": 0}"
```

Panels: hit rate %, request rate (hits/misses/reval/errors), throughput (bytes/s), cache entries over time.

## apt-larder.yml.example

Minimal production config with paths suited for a system install.
Copy to `/etc/apt-larder/apt-larder.yml` and adjust as needed.
