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
- Configure the separate IPv6 firewall identically, or disable IPv6 networking
  on the instance. Dual-stack instances ship with their own default-open IPv6
  rules, so restricting SSH only in the IPv4 firewall leaves TCP 22 reachable
  from anywhere over IPv6.

### 2. Harden the Base Instance

If the instance was created with `chatto-lightsail-launch.sh` as its Lightsail
launch script, the packages, swap file, service account, and directories below
already exist. The launch script cannot reboot or run interactive installs, so
in that case still `sudo reboot` once to apply the kernel upgrade, then skip
ahead to the AWS CLI installation.

From the fresh SSH prompt:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y ca-certificates curl jq tar age unzip gnupg
sudo reboot
```

Reconnect and install the official AWS CLI v2 build rather than Debian's
potentially stale `awscli` package. Copy the public key block published in the
[AWS CLI installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
into `/tmp/aws-cli-public-key.asc`, then verify both the published fingerprint
and the installer signature:

```bash
mkdir -p /tmp/aws-cli-install
cd /tmp/aws-cli-install

curl -fLo awscliv2.zip \
  https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
curl -fLo awscliv2.sig \
  https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip.sig

gpg --import /tmp/aws-cli-public-key.asc
AWS_CLI_FINGERPRINT=$(gpg --with-colons --fingerprint A6310ACC4672475C |
  awk -F: '$1 == "fpr" { print $10; exit }')
test "${AWS_CLI_FINGERPRINT}" = \
  FB5DB77FD5C118B80511ADA8A6310ACC4672475C
gpg --verify awscliv2.sig awscliv2.zip

unzip awscliv2.zip
sudo ./aws/install --bin-dir /usr/local/bin \
  --install-dir /usr/local/aws-cli
/usr/local/bin/aws --version
```

Stop if the fingerprint or signature does not match. The expected output must
identify AWS CLI v2 and the `AWS CLI Team <aws-cli@amazon.com>` signing key.
The signing-key warning about an untrusted certification path is expected; a
bad signature is not.

Confirm Debian and available resources, then add 1 GiB of emergency swap:

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
# The checksum asset is version-templated, e.g. chatto_0.4.14_checksums.txt;
# the tag has a leading "v" that the file name omits.
CHATTO_CHECKSUMS="chatto_${CHATTO_VERSION#v}_checksums.txt"
mkdir -p /tmp/chatto-install
cd /tmp/chatto-install

curl -fLO \
  "https://github.com/chattocorp/chatto/releases/download/${CHATTO_VERSION}/${CHATTO_ASSET}"
curl -fLO \
  "https://github.com/chattocorp/chatto/releases/download/${CHATTO_VERSION}/${CHATTO_CHECKSUMS}"

grep "  ${CHATTO_ASSET}\$" "${CHATTO_CHECKSUMS}" | sha256sum --check -
tar -xzf "${CHATTO_ASSET}"
sudo install -o root -g root -m 0755 chatto /usr/local/bin/chatto

/usr/local/bin/chatto version
```

Record the installed version in the deployment notes. Never pipe an unverified download directly into a privileged shell.

### 4. Generate and Tune Configuration

Generate the secret-bearing configuration as the service account. Run this and
every other `sudo -u chatto` command from a directory the service account can
access, such as `/var/lib/chatto`; launching from `/root` leaves the process
with an unreadable working directory:

```bash
cd /var/lib/chatto
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

Note that `max_users` counts only accounts with a verified email or a linked
SSO identity, so the email-less password accounts this plan creates never
count toward it. It stays here as a backstop against misconfiguration, but the
real cap is that the operator creates at most 10 accounts.

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
# Nothing in this plan scrapes the NATS monitoring endpoint; 0 disables it.
http_port = 0
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

After creating it, log in once and confirm the account actually has owner
powers (server settings are visible). The operator API passes role names
through without a client-side allowlist and `owner` is a real server role, but
the documentation only demonstrates `moderator`, and the documented email-based
`[owners]` failsafe is unusable in this no-email model, so this command is the
only owner-bootstrap path and deserves a one-time check.

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

Use standard Amazon S3, not a Lightsail object-storage bucket. All S3
provisioning, upload, inspection, and download operations use AWS CLI v2.
Chatto remains responsible for producing and restoring its own archive.

### Provision the S3 Bucket

Use two separate AWS identities:

- Run one-time bucket provisioning from an operator workstation or AWS
  CloudShell using an existing administrative identity. Never copy this
  identity's credentials to the Lightsail instance.
- Give the instance a dedicated `chatto-backup` IAM user whose permissions are
  limited to the backup prefix. Lightsail does not provide the EC2
  instance-profile workflow, so this user uses a rotatable access key stored on
  the instance.

Before provisioning, choose a globally unique bucket name and a prefix without
leading or trailing slashes:

```bash
CHATTO_AWS_REGION=AWS_REGION
CHATTO_S3_BUCKET=GLOBALLY_UNIQUE_BUCKET_NAME
CHATTO_BACKUP_PREFIX=chatto/backups
CHATTO_AWS_ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

test -n "${CHATTO_AWS_ACCOUNT_ID}"
```

If the operator identity is not already an administrator, grant it a temporary
inline policy containing the following actions on
`arn:aws:s3:::GLOBALLY_UNIQUE_BUCKET_NAME`, then remove that policy after
provisioning:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProvisionChattoBackupBucket",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:GetBucketLocation",
        "s3:GetBucketOwnershipControls",
        "s3:PutBucketOwnershipControls",
        "s3:GetBucketPublicAccessBlock",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetEncryptionConfiguration",
        "s3:PutEncryptionConfiguration",
        "s3:GetBucketVersioning",
        "s3:PutBucketVersioning",
        "s3:GetLifecycleConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:GetBucketPolicy",
        "s3:GetBucketPolicyStatus",
        "s3:PutBucketPolicy"
      ],
      "Resource": "arn:aws:s3:::GLOBALLY_UNIQUE_BUCKET_NAME"
    }
  ]
}
```

Create the bucket in the same region as Lightsail. `us-east-1` is the only
region for which `LocationConstraint` must be omitted:

```bash
if [ "${CHATTO_AWS_REGION}" = us-east-1 ]; then
  aws s3api create-bucket \
    --bucket "${CHATTO_S3_BUCKET}" \
    --region "${CHATTO_AWS_REGION}" \
    --object-ownership BucketOwnerEnforced
else
  aws s3api create-bucket \
    --bucket "${CHATTO_S3_BUCKET}" \
    --region "${CHATTO_AWS_REGION}" \
    --create-bucket-configuration \
      "LocationConstraint=${CHATTO_AWS_REGION}" \
    --object-ownership BucketOwnerEnforced
fi

aws s3api put-public-access-block \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

aws s3api put-bucket-encryption \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":false}]}'

aws s3api put-bucket-versioning \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled
```

Generate and install the lifecycle configuration. On this versioned bucket the
14-day expiration writes a delete marker, and the noncurrent rule removes the
underlying version 14 days after that, so budget for an archive occupying
storage for up to 28 days in total. A `Days`-based expiration also removes the
resulting expired delete markers automatically once they are old enough, so no
separate delete-marker rule is needed (and S3 rejects a second overlapping
`Expiration` action). The multipart rule cleans up abandoned uploads after one
day:

```bash
jq -n --arg prefix "${CHATTO_BACKUP_PREFIX}/" '{
  Rules: [{
    ID: "chatto-backup-retention",
    Status: "Enabled",
    Filter: {Prefix: $prefix},
    Expiration: {Days: 14},
    NoncurrentVersionExpiration: {NoncurrentDays: 14},
    AbortIncompleteMultipartUpload: {DaysAfterInitiation: 1}
  }]
}' > /tmp/chatto-s3-lifecycle.json

aws s3api put-bucket-lifecycle-configuration \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --lifecycle-configuration file:///tmp/chatto-s3-lifecycle.json
```

Require TLS for every bucket request:

```bash
jq -n --arg bucket "${CHATTO_S3_BUCKET}" '{
  Version: "2012-10-17",
  Statement: [{
    Sid: "DenyInsecureTransport",
    Effect: "Deny",
    Principal: "*",
    Action: "s3:*",
    Resource: [
      ("arn:aws:s3:::" + $bucket),
      ("arn:aws:s3:::" + $bucket + "/*")
    ],
    Condition: {Bool: {"aws:SecureTransport": "false"}}
  }]
}' > /tmp/chatto-s3-bucket-policy.json

aws s3api put-bucket-policy \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --policy file:///tmp/chatto-s3-bucket-policy.json
```

S3 notes that the first versioning enablement can take up to 15 minutes to
propagate. Wait 15 minutes before the first production upload.

### Create the Runtime IAM User

Have an IAM administrator create a user named `chatto-backup` with no console
access. If this is delegated to the provisioning operator, temporarily grant
that operator `iam:CreateUser`, `iam:GetUser`, `iam:GetLoginProfile`,
`iam:PutUserPolicy`, `iam:GetUserPolicy`, `iam:ListUserPolicies`,
`iam:ListAttachedUserPolicies`, `iam:CreateAccessKey`,
`iam:ListAccessKeys`, `iam:UpdateAccessKey`, and `iam:DeleteAccessKey`, scoped to
`arn:aws:iam::AWS_ACCOUNT_ID:user/chatto-backup`. Remove the delegation after
the user and first key are configured.

Replace the three placeholders below, attach the result to `chatto-backup` as
an inline policy named `ChattoBackupPrefix`, and do not attach any AWS managed
S3 policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InspectBucket",
      "Effect": "Allow",
      "Action": "s3:GetBucketLocation",
      "Resource": "arn:aws:s3:::GLOBALLY_UNIQUE_BUCKET_NAME"
    },
    {
      "Sid": "ListBackupPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::GLOBALLY_UNIQUE_BUCKET_NAME",
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "BACKUP_PREFIX",
            "BACKUP_PREFIX/*"
          ]
        }
      }
    },
    {
      "Sid": "UseBackupObjects",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::GLOBALLY_UNIQUE_BUCKET_NAME/BACKUP_PREFIX/*"
    }
  ]
}
```

Create one access key for the `chatto-backup` user using the IAM console's
"Application running outside AWS" use case. Record it directly in the external
password manager; do not download or retain an unencrypted credentials CSV.
Create protected AWS CLI configuration paths on the server:

```bash
sudo install -d -o chatto -g chatto -m 0700 /etc/chatto/aws

sudo -u chatto env \
  AWS_CONFIG_FILE=/etc/chatto/aws/config \
  AWS_SHARED_CREDENTIALS_FILE=/etc/chatto/aws/credentials \
  /usr/local/bin/aws configure --profile chatto-backup

sudo chown chatto:chatto \
  /etc/chatto/aws/config /etc/chatto/aws/credentials
sudo chmod 0600 \
  /etc/chatto/aws/config /etc/chatto/aws/credentials
```

Enter the access key ID, secret access key, the Lightsail region, and `json`
when prompted. The prompt keeps the secret out of shell history. Store a
randomly generated backup passphrase in `/etc/chatto/backup-passphrase`, owned
by `chatto`, mode `0600`; the backup service reads it with
`--passphrase-file`. Keep a second copy of the passphrase and `chatto.toml`
in the external password manager; neither is recoverable from the server if
the disk is lost.

### Automate and Verify Backups

Create a local staging directory for archives:

```bash
sudo install -d -o chatto -g chatto -m 0700 /var/lib/chatto/backups
```

Install a daily systemd service (`chatto-backup.service`) and timer
(`chatto-backup.timer`). The service must run as the service account — it
needs to read `chatto.toml` and the passphrase file — with at least:

```ini
[Service]
Type=oneshot
User=chatto
Group=chatto
WorkingDirectory=/var/lib/chatto/backups
Environment=AWS_CONFIG_FILE=/etc/chatto/aws/config
Environment=AWS_SHARED_CREDENTIALS_FILE=/etc/chatto/aws/credentials
Environment=AWS_PROFILE=chatto-backup
Environment=AWS_REGION=AWS_REGION
Environment=AWS_PAGER=
```

Setting the credentials via environment paths keeps them out of the unit file
itself.

The backup program run by the service must:

1. Run `chatto backup --config /etc/chatto/chatto.toml --encrypt
   --include-keys --passphrase-file /etc/chatto/backup-passphrase -o
   "${BACKUP_ARCHIVE}"`. The passphrase file is mandatory here: without it the
   command prompts interactively, which fails under systemd.
2. Name the archive (`BACKUP_ARCHIVE`, under `/var/lib/chatto/backups/`) with
   a UTC timestamp and `.tar.gz.age` suffix.
3. Calculate its byte count and hexadecimal SHA-256 digest:

   ```bash
   BACKUP_SIZE=$(stat -c %s "${BACKUP_ARCHIVE}")
   BACKUP_SHA256=$(sha256sum "${BACKUP_ARCHIVE}" | awk '{print $1}')
   ```

4. Upload it under `BACKUP_PREFIX/` with explicit encryption, an S3-managed
   transfer checksum, and the full-file SHA-256 stored as object metadata:

   ```bash
   /usr/local/bin/aws s3 cp "${BACKUP_ARCHIVE}" \
     "s3://${S3_BUCKET}/${BACKUP_OBJECT_KEY}" \
     --region "${AWS_REGION}" \
     --sse AES256 \
     --checksum-algorithm SHA256 \
     --metadata "sha256=${BACKUP_SHA256}" \
     --only-show-errors
   ```

5. Run `aws s3api head-object --checksum-mode ENABLED` with
   `--expected-bucket-owner` and fail unless `ContentLength` equals
   `BACKUP_SIZE`, `Metadata.sha256` equals `BACKUP_SHA256`,
   `ChecksumSHA256` is present, and `ServerSideEncryption` equals `AES256`.
   The S3 checksum can be a composite checksum for multipart uploads, so it
   must not be compared directly with the full-file digest.
6. Retain only the newest two local archives, but delete an older local
   archive only after its replacement has passed the remote verification.
7. Exit nonzero on backup, upload, or verification failure so the failure is
   visible in systemd and `journalctl`.

Chatto explicitly recommends encrypted backups with included keys for small servers and remote object storage rather than the same disk. [Backup and restore guide](https://docs.chatto.run/guides/operations/backup-restore/)

Do not auto-update a pre-1.0 server. For each upgrade:

1. Read the release notes.
2. Start the backup service and require a successful checksum-verified S3
   upload before continuing.
3. Download and checksum the new binary.
4. Stop Chatto.
5. Preserve the previous binary as `chatto.previous`.
6. Atomically install the new binary and start Chatto.
7. Check readiness, login, logs, memory, and admin diagnostics.
8. Restore the previous binary if startup or compatibility checks fail.

Test disaster recovery on a temporary instance. Use `aws s3api
list-objects-v2` restricted to `BACKUP_PREFIX/` to select an archive, inspect it
with `head-object --checksum-mode ENABLED`, and download it with `aws s3 cp`.
Recompute the downloaded file's size and full-file SHA-256 and compare them
with `ContentLength` and `Metadata.sha256` before decrypting it. Then stop
Chatto, restore with the passphrase, start it, and confirm the owner can log in
and read messages and attachments.

Rotate the server access key without downtime: create a second access key,
rerun `aws configure --profile chatto-backup`, run and verify a test backup,
then deactivate the old key. Delete the old key only after another scheduled
backup succeeds. Never keep two active keys longer than the rotation window.

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

Verify AWS CLI, the runtime identity, and every S3 control created during
provisioning. Run the identity and object checks with the protected
`chatto-backup` profile; run bucket-configuration checks with the operator
identity because the runtime identity intentionally cannot read or change
those settings:

```bash
/usr/local/bin/aws --version

sudo -u chatto env \
  AWS_CONFIG_FILE=/etc/chatto/aws/config \
  AWS_SHARED_CREDENTIALS_FILE=/etc/chatto/aws/credentials \
  AWS_PROFILE=chatto-backup \
  AWS_PAGER= \
  /usr/local/bin/aws sts get-caller-identity

aws s3api get-bucket-location \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}"
aws s3api get-bucket-ownership-controls \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}"
aws s3api get-public-access-block \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}"
aws s3api get-bucket-encryption \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}"
aws s3api get-bucket-versioning \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}"
aws s3api get-bucket-lifecycle-configuration \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}"
aws s3api get-bucket-policy-status \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}"
aws s3api get-bucket-policy \
  --bucket "${CHATTO_S3_BUCKET}" \
  --expected-bucket-owner "${CHATTO_AWS_ACCOUNT_ID}" \
  --query Policy --output text

aws iam get-user --user-name chatto-backup
aws iam get-user-policy \
  --user-name chatto-backup \
  --policy-name ChattoBackupPrefix
aws iam list-user-policies --user-name chatto-backup
aws iam list-attached-user-policies --user-name chatto-backup
aws iam list-access-keys --user-name chatto-backup

# This must fail with NoSuchEntity, proving there is no console password.
aws iam get-login-profile --user-name chatto-backup

sudo systemctl is-enabled chatto-backup.timer
sudo systemctl list-timers chatto-backup.timer --all
sudo systemctl status chatto-backup.service --no-pager
sudo journalctl -u chatto-backup.service --since "2 days ago"
```

The S3 results must show:

- The bucket is in the Lightsail region. S3 reports `null` or `US` for
  `us-east-1`.
- Object ownership is `BucketOwnerEnforced`.
- All four public-access-block settings are `true`, and bucket policy status
  reports `IsPublic: false`. The decoded bucket policy contains the
  `DenyInsecureTransport` statement.
- Default encryption is `AES256`.
- Versioning is `Enabled`.
- The lifecycle rule applies only to `BACKUP_PREFIX/`, expires current and
  noncurrent objects after 14 days, and aborts incomplete multipart uploads
  after one day.
- The IAM user has no console password, has only the `ChattoBackupPrefix`
  inline policy, and normally has exactly one active access key.

For the newest backup, use the runtime profile to run `list-objects-v2` with
`--prefix "BACKUP_PREFIX/"` and `head-object --checksum-mode ENABLED`.
Confirm that the returned key is below the expected prefix and that its
`ContentLength`, `Metadata.sha256`, and `ServerSideEncryption` match the local
archive and the backup service's recorded values. Also confirm that
`ChecksumSHA256` is present; S3 can return a composite value for multipart
uploads, so the disaster-recovery download is the end-to-end full-file digest
test.

Acceptance requires:

- Public `https://CHAT_HOST` has a valid certificate and redirects HTTP to HTTPS.
- Owner and ordinary password accounts can log in without email.
- Messages, realtime updates, image uploads, and small file downloads work between two browsers.
- Direct registration, video uploads, calls, and search are unavailable.
- Only TCP 22, 80, and 443 are publicly reachable over both IPv4 and IPv6; NATS remains localhost-only and its monitoring port is disabled.
- A reboot brings Chatto back automatically with data intact.
- AWS CLI v2 is installed from a signature-verified official installer.
- The `chatto-backup` credentials can list only `BACKUP_PREFIX`, read and write
  its objects, and cannot change bucket configuration or access another
  prefix.
- No AWS key is present in shell history, systemd unit files, logs, or any
  group/world-readable file.
- A daily encrypted backup appears in S3 with matching size and SHA-256
  checksum and `AES256` server-side encryption, and can be checksum-verified
  and restored on a disposable instance.
- No kernel OOM events occur.
- Under normal use, Chatto RSS remains below roughly 350 MiB, at least 64 MiB remains available, swap is not continuously growing, and disk usage stays below 70%.

If those memory conditions fail, move unchanged data and configuration to the $7/1 GB public-IPv4 bundle. If attachment growth threatens the 20 GB disk, move attachments to S3 or upgrade storage. Calls, video transcoding, higher concurrency, and high availability are explicitly outside this $5 deployment.

## Interfaces and Assumptions

- No Chatto source-code or public API changes are required.
- New operational interfaces are the systemd service, local operator Unix
  socket, AWS CLI v2 profile, backup service/timer, and private S3 prefix.
- Required deployment inputs are `CHAT_HOST`, `ACME_CONTACT_EMAIL`,
  `OWNER_LOGIN`, `OWNER_DISPLAY_NAME`, `AWS_ACCOUNT_ID`, `AWS_REGION`,
  `S3_BUCKET`, `BACKUP_PREFIX`, and the restricted `chatto-backup`
  credentials.
- The $5 figure covers the Lightsail instance only. The attached static IPv4 is free; S3 storage/requests and domain registration are separate charges.
