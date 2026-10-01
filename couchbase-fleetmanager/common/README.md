# Couchbase Fleet Manager

Centralised fleet-wide visibility and management for self-managed Couchbase Server
deployments. Serves both the REST API and the web UI.

Fleet Manager reaches Couchbase over the network only, so it may be installed alongside a
cluster node or on a separate host.

## Installation

Requires systemd. RPMs are built for RHEL 9 and compatible; debs are distro-agnostic and
install on any current Debian or Ubuntu.

**RHEL / compatible:**

```bash
sudo dnf install ./couchbase-fleetmanager-<version>-<release>.el9.x86_64.rpm
```

`rpm -i` also works, but `dnf` handles upgrades correctly and records the transaction.

**Debian / Ubuntu:**

```bash
sudo apt install ./couchbase-fleetmanager_<version>-<bldnum>-linux_amd64.deb
```

Use `apt` rather than `dpkg -i`: the package depends on `adduser` and
`init-system-helpers`, and bare `dpkg -i` will not pull those in on a minimal image.

Either way this creates the `fleetmanager` user and installs the systemd unit, but
**does not enable or start the service** -- configure it first, then enable it explicitly.
Both formats behave the same way here, so nothing comes up half-configured after a reboot.

## Configure

Set `FM_ARGS` in `/etc/couchbase/fleetmanager/fleetmanager.env`; its contents are appended
to the server's command line.

```ini
FM_ARGS=--connection-string couchbase://cluster-host --log-level info
```

| Flag | Default |
| --- | --- |
| `--connection-string couchbase://host1,host2` | `couchbase://localhost` |
| `--bucket-name <name>` | `default` |
| `--scope-name <name>` | `fleetmanager` |
| `--port <n>` | 443 (80 with `--insecure`) |
| `--cert <path> --key <path>` | self-signed |
| `--log-level debug\|info\|warn\|error` | `info` |

`--ui-dir` and `--credentials-dir` are already set by the unit file. Run
`/opt/couchbase/fleetmanager/bin/fleetmanager-server --help` for the full list.

Keep secrets out of this file -- everything in `FM_ARGS` is visible through `/proc`.

## Credentials

Cluster credentials live in `/opt/couchbase/var/lib/fleetmanager/credentials.json`, which
the server generates on first start. To pre-seed it instead:

```bash
sudo install -o fleetmanager -g fleetmanager -m 0600 \
    /usr/share/doc/couchbase-fleetmanager/credentials.json.example \
    /opt/couchbase/var/lib/fleetmanager/credentials.json
sudo -u fleetmanager vi /opt/couchbase/var/lib/fleetmanager/credentials.json
```

## Upgrading and removing

Both packages preserve `credentials.json` through an uninstall, including `apt purge`, and
neither removes the `fleetmanager` user.

`fleetmanager.env` is handled the way each format handles configuration, which differs in
two visible ways:

| | RPM | Deb |
| --- | --- | --- |
| Upgrade, after local edits | keeps your file silently, writes `.rpmnew` alongside | **prompts you**, writes `.dpkg-dist` alongside |
| Uninstall | kept | kept by `apt remove`, deleted by `apt purge` |

The upgrade prompt on Debian is normal `dpkg` behaviour, not a fault. Pass
`-o Dpkg::Options::=--force-confold` to keep your version without being asked.

## Start

```bash
sudo systemctl enable --now couchbase-fleetmanager
systemctl status couchbase-fleetmanager
journalctl -u couchbase-fleetmanager -f
```

The UI and REST API are served on the configured port, over HTTPS with a self-signed
certificate unless `--cert`/`--key` are set.

## First login

Log in with the default account:

| Username | Password |
| --- | --- |
| `admin` | `Fl33tm@n@ger` |

You are prompted to set a new password on first login.

These are the UI credentials, separate from the Couchbase cluster credentials in
`credentials.json`.
