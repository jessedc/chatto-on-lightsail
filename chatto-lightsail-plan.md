# Chatto on a $5 Lightsail Debian Instance

## Summary and Feasibility

This is feasible for the selected workload: a private community with at most 10 active users, core chat, images/files, no video transcoding, no voice/video calls, and operator-managed accounts.

- Target the $5 public-IPv4 Lightsail bundle: 2 vCPUs, 512 MB RAM, 20 GB SSD, and 1 TB transfer. The $5 compute price excludes S3 backup charges and any domain-registration cost. [Lightsail bundle specifications](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html)
- Debian 13 is an available Lightsail blueprint. [Supported Lightsail blueprints](https://docs.aws.amazon.com/lightsail/latest/userguide/compare-options-choose-lightsail-instance-image.html)
- Chatto supports a single-process deployment containing the web app and embedded NATS/JetStream, with no external database or proxy. [Standalone deployment](https://docs.chatto.run/guides/deployment/binary/)
- Releases are statically built for Linux amd64 and arm64 (`CGO_ENABLED=0`), so Debian 13 compatibility is straightforward. [Release configuration](https://github.com/chattocorp/chatto/blob/main/.goreleaser.yml)
- There is no published 512 MB minimum. The source's larger Kubernetes example requests 128 MiB for Chatto and 256 MiB for separate NATS, while allowing substantially higher limits. The standalone process combines both, so 512 MB is viable but tight and requires swap, conservative features, and monitoring. [Chatto resources](https://github.com/chattocorp/chatto/blob/main/examples/k8s/chatto.yaml), [NATS resources](https://github.com/chattocorp/chatto/blob/main/examples/k8s/nats.yaml)
- Do not deploy Docker Compose, LiveKit, ffmpeg, or the search provider on this plan. Upgrade to at least the $7/1 GB public-IPv4 bundle if the acceptance thresholds below are not met.

## Implementation Runbook

### 1. Prepare Lightsail and DNS

Before connecting to the command prompt:

- Create a Debian 13 instance using the $5 public-IPv4 bundle.
- Attach a Lightsail static IPv4 address. It is free while attached and prevents DNS from changing after a stop/start. [Static IP guidance](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-static-ip-addresses-in-amazon-lightsail.html)
- Add an `A` record for `CHAT_HOST`, such as `chat.example.com`, pointing to that static IP. This can be in Lightsail DNS or the existing DNS provider. [Lightsail DNS records](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-dns-in-amazon-lightsail.html)
- Wait until `dig +short CHAT_HOST A` returns the static IP.
- Configure the Lightsail IPv4 firewall:
  - TCP 80 from anywhere for ACME and HTTPS redirects.
  - TCP 443 from anywhere for Chatto.
  - TCP 22 restricted to the operator's public IP where practical.
  - Remove every other inbound rule.

### 2. Harden the Base Instance

From the fresh SSH prompt:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y ca-certificates curl jq tar age awscli
sudo reboot
```

Reconnect, confirm Debian and available resources, then add 1 GiB of emergency swap:

```bash
cat /etc/debian_version
free -h
df -h /

sudo fallocate -l 1G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/90-chatto-memory.conf
sudo sysctl --system
```

Create a dedicated non-login account and private directories:

```bash
sudo useradd --system --create-home \
  --home-dir /var/lib/chatto \
  --shell /usr/sbin/nologin chatto

sudo install -d -o chatto -g chatto -m 0750 \
  /etc/chatto /var/lib/chatto/data /var/lib/chatto/certs
```

### 3. Install and Verify Chatto

Resolve the latest stable release, download the Linux x86-64 archive and checksum file, verify the archive, and install the binary:

```bash
CHATTO_VERSION=$(curl -fsSL \
  https://api.github.com/repos/chattocorp/chatto/releases/latest | \
  jq -r .tag_name)

CHATTO_ASSET=chatto_Linux_x86_64.tar.gz
mkdir /tmp/chatto-install
cd /tmp/chatto-install

curl -fLO \
  "https://github.com/chattocorp/chatto/releases/download/${CHATTO_VERSION}/${CHATTO_ASSET}"
curl -fLO \
  "https://github.com/chattocorp/chatto/releases/download/${CHATTO_VERSION}/checksums.txt"

grep "  ${CHATTO_ASSET}\$" checksums.txt | sha256sum --check -
tar -xzf "${CHATTO_ASSET}"
sudo install -o root -g root -m 0755 chatto /usr/local/bin/chatto

/usr/local/bin/chatto version
```

Record the installed version in the deployment notes. Never pipe an unverified download directly into a privileged shell.

### 4. Generate and Tune Configuration

Generate the secret-bearing configuration as the service account:

```bash
sudo -u chatto /usr/local/bin/chatto init \
  --config /etc/chatto/chatto.toml
sudo chmod 600 /etc/chatto/chatto.toml
```

Retain the generated cookie, core, asset, and NATS secrets. Edit only the relevant settings:

- Set `webserver.url = "https://CHAT_HOST"` and `webserver.port = 443`.
- Set exact same-origin access with `allowed_origins = ["https://CHAT_HOST"]`.
- Disable API and WebSocket compression to reduce peak memory.
- Enable built-in TLS with:

```toml
[webserver.tls]
enabled = true
domain = "CHAT_HOST"
email = "ACME_CONTACT_EMAIL"
cache_dir = "/var/lib/chatto/certs"
http_port = 80
```

`ACME_CONTACT_EMAIL` is required by Chatto for Let's Encrypt registration; it does not require SMTP and need not be a Chatto user account.

Configure the selected private, no-email account model:

```toml
[auth]
direct_registration = false

[smtp]
enabled = false

[limits]
max_users = 10

[operator_api]
enabled = true
socket_path = "/run/chatto/operator.sock"
```

Apply the low-resource feature policy:

```toml
[search]
enabled = false

[search_provider]
enabled = false

[video]
enabled = false

[livekit]
enabled = false
```

Keep embedded NATS and local attachment storage:

```toml
[nats]
replicas = 1

[nats.embedded]
enabled = true
port = 4222
bind_address = "127.0.0.1"
http_port = 8222
data_dir = "/var/lib/chatto/data"
# Retain the auth_token generated by `chatto init`.

[core.assets]
storage_backend = "nats"
max_upload_size = "10 MB"
# Retain the generated signing_secret.

[core.assets.cache]
enabled = false
```

The localhost NATS listener is needed by Chatto's backup command and must never be exposed through the Lightsail firewall.

### 5. Install the systemd Service

Create `/etc/systemd/system/chatto.service` with:

```ini
[Unit]
Description=Chatto
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=chatto
Group=chatto
WorkingDirectory=/var/lib/chatto
ExecStart=/usr/local/bin/chatto run --config /etc/chatto/chatto.toml
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
RuntimeDirectory=chatto
RuntimeDirectoryMode=0700
UMask=0077

Environment=GOMEMLIMIT=320MiB
Environment=GOGC=50

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/chatto /run/chatto
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Validate and start it:

```bash
sudo systemd-analyze verify /etc/systemd/system/chatto.service
sudo systemctl daemon-reload
sudo systemctl enable --now chatto
sudo systemctl status chatto --no-pager
sudo journalctl -u chatto -n 100 --no-pager
```

### 6. Bootstrap Operator-Managed Accounts

Create the first account with the protected `owner` role. The CLI prompts for a password without placing it in shell history:

```bash
sudo -u chatto /usr/local/bin/chatto operator \
  --config /etc/chatto/chatto.toml \
  user create \
  --login OWNER_LOGIN \
  --display-name "OWNER_DISPLAY_NAME" \
  --role owner
```

Create ordinary users without `--role owner`. Public registration remains disabled. Forgotten passwords are reset locally:

```bash
sudo -u chatto /usr/local/bin/chatto operator \
  --config /etc/chatto/chatto.toml \
  user list --search MEMBER_LOGIN

sudo -u chatto /usr/local/bin/chatto operator \
  --config /etc/chatto/chatto.toml \
  user set-password USER_ID
```

This avoids SMTP and external identity services, but all account creation and recovery requires SSH/operator access. [Operator CLI](https://docs.chatto.run/guides/operations/operator-cli/)

## Backups, Upgrades, and Operations

- Create a private S3 bucket in the same AWS region, block all public access, and give Chatto credentials limited to listing and reading/writing/deleting one backup prefix.
- Configure a bucket lifecycle that retains daily archives for 14 days and expires noncurrent versions.
- Store the credentials and a randomly generated backup passphrase in `/etc/chatto/`, owned by `chatto`, mode `0600`. Keep a second copy of the passphrase and `chatto.toml` in an external password manager; neither is recoverable from the server if the disk is lost.
- Install a daily systemd timer that:
  1. Runs `chatto backup --encrypt --include-keys`.
  2. Uses a UTC timestamped `.tar.gz.age` filename.
  3. Uploads the completed archive with `aws s3 cp`.
  4. Verifies it with `aws s3api head-object`.
  5. Retains only the newest two local archives.
  6. Fails visibly in systemd if creation or upload fails.

Chatto explicitly recommends encrypted backups with included keys for small servers and remote object storage rather than the same disk. [Backup and restore guide](https://docs.chatto.run/guides/operations/backup-restore/)

Do not auto-update a pre-1.0 server. For each upgrade:

1. Read the release notes.
2. Create and verify an off-site backup.
3. Download and checksum the new binary.
4. Stop Chatto.
5. Preserve the previous binary as `chatto.previous`.
6. Atomically install the new binary and start Chatto.
7. Check readiness, login, logs, memory, and admin diagnostics.
8. Restore the previous binary if startup or compatibility checks fail.

Test disaster recovery on a temporary instance: download an encrypted archive, stop Chatto, restore with the passphrase, start it, and confirm the owner can log in and read messages and attachments.

## Verification and Acceptance Criteria

Verify the deployment with:

```bash
sudo systemctl is-active chatto
curl --fail --resolve CHAT_HOST:443:127.0.0.1 \
  https://CHAT_HOST/healthz
curl --fail --resolve CHAT_HOST:443:127.0.0.1 \
  https://CHAT_HOST/readyz
sudo ss -lntup
free -h
df -h /
sudo journalctl -u chatto --since "15 minutes ago"
```

Acceptance requires:

- Public `https://CHAT_HOST` has a valid certificate and redirects HTTP to HTTPS.
- Owner and ordinary password accounts can log in without email.
- Messages, realtime updates, image uploads, and small file downloads work between two browsers.
- Direct registration, video uploads, calls, and search are unavailable.
- Only TCP 22, 80, and 443 are publicly reachable; NATS and its monitor remain localhost-only.
- A reboot brings Chatto back automatically with data intact.
- A daily encrypted backup appears in S3 and can be restored on a disposable instance.
- No kernel OOM events occur.
- Under normal use, Chatto RSS remains below roughly 350 MiB, at least 64 MiB remains available, swap is not continuously growing, and disk usage stays below 70%.

If those memory conditions fail, move unchanged data and configuration to the $7/1 GB public-IPv4 bundle. If attachment growth threatens the 20 GB disk, move attachments to S3 or upgrade storage. Calls, video transcoding, higher concurrency, and high availability are explicitly outside this $5 deployment.

## Interfaces and Assumptions

- No Chatto source-code or public API changes are required.
- New operational interfaces are the systemd service, local operator Unix socket, backup timer, and private S3 prefix.
- Required deployment inputs are `CHAT_HOST`, `ACME_CONTACT_EMAIL`, `OWNER_LOGIN`, `OWNER_DISPLAY_NAME`, AWS region, S3 bucket/prefix, and restricted S3 credentials.
- The $5 figure covers the Lightsail instance only. The attached static IPv4 is free; S3 storage/requests and domain registration are separate charges.
