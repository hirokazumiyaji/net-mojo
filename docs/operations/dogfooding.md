# Continuous dogfooding

Run the core HTTP/1.1 example on a Linux VM using the pinned compiler. The
service exposes `/json`, a bounded `POST /echo`, and Prometheus text metrics
at `/metrics`. It binds to `127.0.0.1:8080` by default. Set `DOGFOOD_ADDRESS`
to change the bind address. No public endpoint or optional provider is needed.

## Build and install

Build on the VM's target architecture inside `/opt/net-mojo`. Keep this checkout
and its `.pixi/envs/default` environment at that path: Mojo executables link to
the compiler's shared runtime libraries. Copying the executable alone is not
a deployment. The service's `ProtectHome=true` also prevents it from loading
a runtime installed under an operator's home directory.

```bash
sudo install -d -m 755 /opt/net-mojo
sudo chown "$(id -un):$(id -gn)" /opt/net-mojo
git clone https://github.com/hirokazumiyaji/net-mojo.git /opt/net-mojo
cd /opt/net-mojo
git checkout <revision-being-evaluated>
pixi install --frozen
pixi run dogfood-build
pixi run dogfood-smoke
sudo useradd --system --no-create-home --shell /usr/sbin/nologin net-mojo
sudo install -m 644 deploy/dogfood/net-mojo-dogfood.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now net-mojo-dogfood
curl --fail http://127.0.0.1:8080/metrics
```

Create the checkout and service account once. The service runs without root
privileges and reads the executable and runtime from `/opt/net-mojo`.
The unit uses `Restart=on-failure`; record failures before restarting it
manually. A deployment or manual restart resets the process uptime metric.

## Weekly record

Before deploying the next weekly build, save the observations below in an
operator-owned log. Keep the revision, timestamps, metrics, and journal output
together. The journal is needed because systemd's `NRestarts` counter covers
automatic restarts and can reset when a unit is stopped or restarted.

```bash
date -u
git rev-parse HEAD
curl --fail http://127.0.0.1:8080/metrics
systemctl show net-mojo-dogfood --property=ActiveState,ExecMainStartTimestamp,NRestarts
journalctl -u net-mojo-dogfood --since '7 days ago' --no-pager
```

Exercise `/json` and `/echo` during the week, with small bounded payloads.
Before an upgrade, verify that `net_mojo_uptime_seconds` reached at least
604800 and that the journal shows no intervening restart. Archive the evidence
before rebuilding and restarting the service. For the next revision, stop the
unit, update this checkout, run `pixi install --frozen`, repeat the build and
smoke test, and run `sudo systemctl start net-mojo-dogfood`. Stopping before
changing the environment prevents a running process from using replaced
runtime libraries. Record this planned restart in the log.

## Acceptance evidence

The local smoke test proves HTTP responses, binary echo, HEAD handling, request
counting, and a rising uptime metric. It does not prove one week of operation.
Complete #226's dogfooding requirement only after a real VM has recorded a
continuous week of uptime. No such deployment or uptime record is bundled here.
