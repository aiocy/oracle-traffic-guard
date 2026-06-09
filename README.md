# Oracle Traffic Guard

Interactive installer for VPS/Oracle monthly outbound traffic protection.

It installs a vnStat-based monthly TX monitor plus a high-priority nftables SSH-only fuse. When outbound monthly traffic approaches the configured limit, it sends Telegram alerts. At the fuse threshold, it installs an `inet hermes_guard` nftables table with hook priority `-500`, intended to run before regular Podman/rfw/iptables-nft rules.

## Files

- `install.en.sh` — English interactive installer.
- `install.zh.sh` — 中文交互式安装脚本。

## Quick install

English:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aiocy/oracle-traffic-guard/main/install.en.sh)
```

中文：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aiocy/oracle-traffic-guard/main/install.zh.sh)
```

## Default behavior

- Monitor interface: auto-detected, usually `enp0s6`.
- Metric: monthly TX/outbound traffic from vnStat.
- Warnings: 8 TiB, 9 TiB, 9.5 TiB by default.
- SSH-only fuse: 9.7 TiB by default.
- Cron: every 5 minutes.
- Monthly restore: day 1 at 00:10.

## Installed files on target host

```text
/root/oracle-traffic-guard.env      # local config and Telegram token, chmod 600
/root/oracle-traffic-guard.sh       # monitor / alert / fuse script
/root/oracle-traffic-restore.sh     # manual/monthly restore script
/etc/cron.d/oracle-traffic-guard    # scheduled checks
/var/lib/oracle-traffic-guard/      # state files
/var/log/oracle-traffic-guard.log   # log
```

## Security notes

- This repository does **not** contain Telegram tokens, OCI API keys, SSH keys, passwords, private IPs, or deployment-specific secrets.
- Telegram credentials are prompted interactively and written only on the target host to `/root/oracle-traffic-guard.env` with mode `600`.
- The SSH-only fuse keeps the configured SSH port open and drops other new traffic through nftables.
- Always verify the SSH port during installation. If the wrong SSH port is entered, future fuse mode can lock out normal SSH access.

## Manual restore

If fuse mode is active and you want to restore networking before the monthly automatic restore:

```bash
/root/oracle-traffic-restore.sh
```

## License

MIT
