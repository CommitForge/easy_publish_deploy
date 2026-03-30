# Server Timer/Cron Wiring

This directory contains optional `systemd` files for periodically triggering:

- `POST /izipublish/update-chain/sync`

## Files

- `server/root/izipublish/cron/izipublish_sync.sh`
- `server/etc/systemd/system/izipublish_sync.service`
- `server/etc/systemd/system/izipublish_sync.timer`
- `server/etc/default/izipublish_sync`

## Install

1. Copy files to target server (compatible with your current `/root/izipublish/...` layout):

```bash
sudo mkdir -p /root/izipublish/cron
sudo cp server/root/izipublish/cron/izipublish_sync.sh /root/izipublish/cron/
sudo chmod 700 /root/izipublish/cron/izipublish_sync.sh

sudo cp server/etc/systemd/system/izipublish_sync.service /etc/systemd/system/
sudo cp server/etc/systemd/system/izipublish_sync.timer /etc/systemd/system/
sudo cp server/etc/default/izipublish_sync /etc/default/izipublish_sync
```

2. Edit `/etc/default/izipublish_sync` values (`SYNC_BACKEND_BASE_URL`, chain IDs, optional script path).

3. Enable timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now izipublish_sync.timer
```

4. Check status:

```bash
sudo systemctl status izipublish_sync.timer
sudo systemctl status izipublish_sync.service
```
