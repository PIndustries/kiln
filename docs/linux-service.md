# Linux boot service

The supplied `deploy/kiln.service` runs as a dedicated `kiln` user, starts at boot, and retries supervisor failures with a bounded systemd restart policy. SSH stays on loopback port 2222 unless the unit is deliberately changed. Use an existing host SSH tunnel to reach it.

Build Linux binaries with Swift 6.2.3, retaining the Swift runtime libraries required by that build. A macOS binary cannot run on Linux. The service template assumes `/opt/kiln/kiln` is already executable on the target host; test `--version` under the service user before starting it.

Example host setup (review paths before running):

```sh
sudo useradd --system --home-dir /var/lib/kiln --shell /usr/sbin/nologin kiln
sudo install -d -m 0755 /opt/kiln /etc/kiln
sudo install -m 0755 .build/release/kiln /opt/kiln/kiln
sudo install -m 0644 /path/to/admin.pub /etc/kiln/authorized_keys
sudo install -m 0644 deploy/kiln.service /etc/systemd/system/kiln.service
sudo systemctl daemon-reload
sudo systemctl enable --now kiln
sudo systemctl status kiln
sudo journalctl -u kiln
```

Initialize Vault with its master key outside `/var/lib/kiln`, readable only by the `kiln` user. A state backup without that external key cannot restore secrets. Preserve both using separate protected backup procedures.

The service's control-group shutdown terminates all its children, including remote terminal sessions. A supervisor failure or host reboot interrupts network connections; recovery restores desired applications, not open client sockets. The unit does not provide application sandboxing or per-module resource quotas.

Upgrade by staging a new binary, stopping the service cleanly, replacing the binary, and starting the service. Never overwrite an executable being used by the runtime or its guardians. Preserve the state directory and matching guardian binary. Check SSH status, application readiness and committed release versions after upgrade.

The crash integration script uses disposable state and actually kills supervisors; it does not reboot the host. Real VM reboot verification is a separate release check. Never run a reboot experiment on a shared production host.
