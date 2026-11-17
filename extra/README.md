# extra/

Files for running apt-larder as a system service.

## apt-larder.service

systemd unit file. Uses `Type=notify` — systemd waits for `READY=1` before
considering the service started. Includes watchdog and basic hardening.

```sh
# Install the binary: download apt-larder-linux-<arch> and its .sha256 from
# https://github.com/jbox-web/apt-larder/releases/latest, then
sha256sum -c apt-larder-linux-amd64.sha256
sudo install -m755 apt-larder-linux-amd64 /usr/local/bin/apt-larder

# Create the service user first: the config file below belongs to its group
# (systemd manages the cache and log directories)
sudo useradd -r -s /usr/sbin/nologin apt-larder

# Install the unit and the config. The config may hold the admin credentials:
# readable by root and by the service group, by nobody else.
sudo install -Dm644 apt-larder.service /etc/systemd/system/apt-larder.service
sudo install -Dm640 -o root -g apt-larder apt-larder.yml.example /etc/apt-larder/apt-larder.yml

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
If the new file cannot be opened, apt-larder keeps writing to the rotated one and says so there.

## grafana-dashboard.json

Grafana dashboard for the Prometheus metrics exposed at `/api/metrics`.

Import via **Dashboards → Import → Upload JSON file**, or via the API:

```sh
curl -X POST http://grafana:3000/api/dashboards/import \
  -H 'Content-Type: application/json' \
  -u admin:admin \
  -d "{\"dashboard\": $(cat grafana-dashboard.json), \"overwrite\": true, \"folderId\": 0}"
```

Panels — overview: hit rate, cached files, total bytes served, cache size, errors (last hour); traffic: request rate (hits/misses/revalidations/errors/tunnels), hit rate %, throughput (bytes/s), cache entries and cache size over time.

## apt-larder.yml.example

Minimal production config with paths suited for a system install.
Copy to `/etc/apt-larder/apt-larder.yml` and adjust as needed.
