# Chatto on Lightsail

This repository installs a private, low-resource Chatto deployment on an
existing Debian 13 Lightsail instance. The primary audience is the human
operator responsible for the AWS account, DNS, credentials, recovery material,
and production acceptance. The scripts automate repeatable mechanics and stop
at human security boundaries.

The deployment remains pinned to Chatto `v0.4.14`. The complete architecture,
manual fallback, operational procedures, and acceptance rationale are in
[`chatto-lightsail-plan.md`](chatto-lightsail-plan.md).

## Before installation

Create the Debian 13 instance, attach a static IPv4 address, and point the
chosen chat hostname at it. Configure both Lightsail firewalls:

- TCP 80 and 443 from anywhere.
- TCP 22 only from the operator's public IP where practical.
- No other inbound ports.

Install AWS CLI v2 and `jq` on the operator workstation. Authenticate AWS CLI
with the administrative identity that may provision the backup bucket, SNS
topic, and restricted IAM user.

Copy and edit the literal deployment input file:

```bash
cp chatto-deploy.env.example chatto-deploy.env
chmod 0600 chatto-deploy.env
```

Do not add shell quotes. Values are read literally, without shell evaluation.
Create and save a random backup passphrase of at least 24 characters in the
external password manager before running the host installation.

## 1. Provision AWS

Run from the operator workstation:

```bash
chmod +x provision-aws.sh
./provision-aws.sh \
  --env chatto-deploy.env \
  --output chatto-provisioned.env \
  --access-key-output chatto-access-key.env
```

The command creates and verifies the S3 bucket controls, SNS topic, restricted
`chatto-backup` IAM user, and runtime policy. It writes:

- `chatto-provisioned.env`: non-secret, normalized deployment inputs.
- `chatto-access-key.env`: the one-time runtime access key, mode `0600`.

The first run normally stops after AWS sends the SNS confirmation email.
Confirm the subscription, then rerun without creating another access key:

```bash
./provision-aws.sh \
  --env chatto-deploy.env \
  --output chatto-provisioned.env
```

Store the access-key secret in the password manager. AWS never reveals it
again.

## 2. Transfer the host installer

Build a deterministic archive containing only host-side artifacts:

```bash
tar -czf /tmp/chatto-host-installer.tgz -T host-installer-files.txt
```

Replace `LIGHTSAIL_IP` below with the instance's static IP:

```bash
scp \
  /tmp/chatto-host-installer.tgz \
  chatto-provisioned.env \
  chatto-access-key.env \
  admin@LIGHTSAIL_IP:

ssh admin@LIGHTSAIL_IP
mkdir -p chatto-on-lightsail
tar -xzf chatto-host-installer.tgz -C chatto-on-lightsail
mv chatto-provisioned.env chatto-access-key.env chatto-on-lightsail/
cd chatto-on-lightsail
chmod +x install-host.sh verify-deployment.sh
```

The Debian Lightsail image normally uses `admin` as its SSH user. Use the
actual blueprint user if it differs.

## 3. Prepare and reboot the host

```bash
sudo ./install-host.sh prepare
sudo reboot
```

The prepare phase is idempotent. It configures the 1 GiB swap file, installs
base packages, upgrades Debian, and creates the locked-down `chatto` service
account. It deliberately does not hide the required reboot.

Reconnect after the instance returns:

```bash
cd chatto-on-lightsail
sudo ./install-host.sh install \
  --env chatto-provisioned.env \
  --credentials chatto-access-key.env
```

The install phase:

- Signature-verifies and installs official AWS CLI v2.
- Checksum-verifies and installs Chatto `v0.4.14`.
- Generates Chatto's secret-bearing configuration without overwriting it on a
  rerun.
- Installs the low-memory, private-community policy through
  `/etc/chatto/chatto.env`.
- Installs and starts the hardened service, backups, alerts, reboot check, and
  Debian security-update policy.
- Prompts for the externally stored backup passphrase.
- Prompts Chatto to create the owner password without placing it in shell
  history.

After it succeeds, remove the transferred access-key file from the server. The
installed copy remains protected at `/etc/chatto/aws/credentials`:

```bash
rm chatto-access-key.env
```

Remove the workstation copy after confirming its value is safely stored in the
password manager.

## 4. Verify the deployment

Run the live backup and alert paths:

```bash
sudo ./verify-deployment.sh --run-backup --send-alert
```

Confirm the test email arrives. Log in as the owner, create an ordinary member
over SSH, and verify messaging and a 10 MB attachment between two browsers.
The member command prompts for its password:

```bash
sudo -u chatto /usr/local/bin/chatto operator \
  --config /etc/chatto/chatto.toml \
  --operator-socket /run/chatto/operator.sock \
  user create \
  --login MEMBER_LOGIN \
  --display-name "Member Name"
```

Before accepting a $5/512 MB instance for production, sustain that browser
workload and run the 15-minute capacity gate:

```bash
sudo ./verify-deployment.sh --capacity
```

Resize to the $7/1 GB bundle and rerun the gate if any threshold fails.
Quarterly restore rehearsal and ongoing maintenance remain human operational
responsibilities; follow the full runbook.

## Repository validation

The non-destructive workflow test uses a deterministic AWS CLI stand-in:

```bash
tests/operator-workflow-test.sh
```

The full static gate is:

```bash
bash -n \
  chatto-operator-lib.sh provision-aws.sh install-host.sh \
  verify-deployment.sh chatto-lightsail-*.sh
shellcheck -x \
  chatto-operator-lib.sh provision-aws.sh install-host.sh \
  verify-deployment.sh chatto-lightsail-*.sh tests/*.sh
```

## Reruns and recovery

- `install-host.sh prepare` may be rerun safely after a partial base setup.
- `install-host.sh install` preserves existing Chatto secrets, AWS
  credentials, the backup passphrase, and the recorded owner.
- `provision-aws.sh` reconciles resource controls but refuses unexpected IAM
  policies, console access, extra keys, or a mismatched AWS account.
- Neither installer upgrades or downgrades an existing different Chatto
  version. Use the runbook's verified backup and manual upgrade procedure.
- A true recovery also needs the password-manager copies of
  `/etc/chatto/chatto.toml`, `/etc/chatto/chatto.env`, and the backup
  passphrase.
