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

Choose the Lightsail region and record the instance name. Create the Debian 13
instance in that region, attach a static IPv4 address, and point the chosen chat
hostname at it. This workflow evaluates the $5 public-IPv4 bundle; start with the
$7/1 GB bundle instead if avoiding a snapshot-based replacement when the
capacity gate fails is more important than testing the lowest-cost option.

Configure both Lightsail firewalls with the bootstrap rules:

- TCP 80 and 443 from anywhere.
- TCP 22 only from the operator's public IP where practical. This rule is
  temporary: administrative SSH moves onto the tailnet, and the final
  SSH-lockdown step removes public TCP 22 from both firewalls.
- No other inbound ports.

Install AWS CLI v2 and `jq` on the operator workstation. Authenticate AWS CLI
with the administrative identity that may provision the backup bucket, SNS
topic, and restricted IAM user.

Prepare the tailnet on a Tailscale account whose workstation and other
operator devices are already enrolled:

Add `tag:chatto` to the tailnet policy file. `tagOwners` controls who may apply
the tag; it does not grant network access. Add a grant that permits the intended
operator identity or group to reach TCP 22 on the tagged server. For an
administrator-only setup:

```json
{
  "tagOwners": {
    "tag:chatto": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["autogroup:admin"],
      "dst": ["tag:chatto"],
      "ip": ["tcp:22"]
    }
  ]
}
```

Merge these entries into the existing policy rather than replacing unrelated
rules. Tailnets using legacy ACLs need the equivalent TCP 22 allow rule. Tagged
nodes have no node-key expiry, so ordinary SSH over the tailnet never lapses
silently. Tailscale SSH itself remains disabled.

- In the admin console, create an auth key that is pre-authorized,
  **not** reusable, not ephemeral, and tagged `tag:chatto`.
- Save it on the workstation as a one-time input file:

```bash
printf 'TS_AUTHKEY=tskey-auth-REPLACE\n' > chatto-tailscale-authkey.env
chmod 0600 chatto-tailscale-authkey.env
```

Copy and edit the literal deployment input file:

```bash
cp chatto-deploy.env.example chatto-deploy.env
chmod 0600 chatto-deploy.env
```

Do not add shell quotes. Values are read literally, without shell evaluation.
Set `CHATTO_AWS_REGION` to the region containing the Lightsail instance, choose
a globally unique S3 bucket name, and leave `CHATTO_AWS_ACCOUNT_ID` and
`CHATTO_SNS_TOPIC_ARN` blank: provisioning fills those generated values.

Create and save a random backup passphrase of at least 24 characters and a
strong owner password in the external password manager before running the host
installation. The installer prompts for both without placing either value in
shell history.

## Repository preflight

Run these portable checks from the repository root before provisioning or
copying artifacts:

```bash
tests/operator-workflow-test.sh
bash -n \
  chatto-operator-lib.sh provision-aws.sh install-host.sh \
  verify-deployment.sh chatto-lightsail-*.sh
```

If ShellCheck is installed, also run:

```bash
shellcheck -x \
  chatto-operator-lib.sh provision-aws.sh install-host.sh \
  verify-deployment.sh chatto-lightsail-*.sh tests/*.sh
```

`systemd-analyze` is not normally available on macOS or Windows. The host
installer validates every installed unit with `systemd-analyze verify` on
Debian before starting the services.

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

Build a fixed-manifest archive containing only host-side artifacts:

```bash
tar -czf /tmp/chatto-host-installer.tgz -T host-installer-files.txt
```

Replace `LIGHTSAIL_IP` below with the instance's static IP:

```bash
scp \
  /tmp/chatto-host-installer.tgz \
  chatto-provisioned.env \
  chatto-access-key.env \
  chatto-tailscale-authkey.env \
  admin@LIGHTSAIL_IP:

ssh admin@LIGHTSAIL_IP
mkdir -p chatto-on-lightsail
tar -xzf chatto-host-installer.tgz -C chatto-on-lightsail
mv chatto-provisioned.env chatto-access-key.env \
  chatto-tailscale-authkey.env chatto-on-lightsail/
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
  --credentials chatto-access-key.env \
  --tailscale-authkey chatto-tailscale-authkey.env
```

The install phase:

- Signature-verifies and installs official AWS CLI v2.
- Checksum-verifies and installs Chatto `v0.4.14`.
- Installs fingerprint-pinned Tailscale from the official Debian repository
  and enrolls the host in the tailnet, deliberately without Tailscale SSH:
  host `sshd` and the Lightsail keypair stay the only SSH path.
- Generates Chatto's secret-bearing configuration without overwriting it on a
  rerun.
- Installs the low-memory, private-community policy through
  `/etc/chatto/chatto.env`.
- Installs and starts the hardened service, backups, alerts, reboot check, and
  Debian security-update policy.
- Prompts for the externally stored backup passphrase.
- Prompts Chatto to create the owner password without placing it in shell
  history.

## 4. Preserve recovery material and remove temporary secrets

After installation succeeds, open another workstation terminal and copy the
secret Chatto configuration directly into a mode-`0600` recovery archive:

```bash
umask 077
ssh admin@LIGHTSAIL_IP \
  'sudo tar -C /etc/chatto -czf - chatto.toml chatto.env' \
  > chatto-recovery-config.tgz
chmod 0600 chatto-recovery-config.tgz
tar -tzf chatto-recovery-config.tgz
```

Store that archive in the external password manager together with:

- The owner password and backup passphrase.
- The `chatto-backup` access key ID and secret.
- The non-secret `chatto-provisioned.env` deployment record.

Require the password-manager copies to be readable before deleting any
temporary file. In the original server terminal, remove the transferred
credential and auth-key inputs. The installed AWS copy remains protected at
`/etc/chatto/aws/credentials`, and the consumed Tailscale auth key is
single-use:

```bash
rm chatto-access-key.env chatto-tailscale-authkey.env
```

On the workstation, remove the temporary secret files after confirming their
password-manager copies:

```bash
rm chatto-access-key.env \
  chatto-tailscale-authkey.env \
  chatto-recovery-config.tgz
```

The auth key needs no retained copy: a future re-enrollment uses a freshly
minted key.

## 5. Verify the deployment

Run the live backup and alert paths:

```bash
sudo ./verify-deployment.sh --run-backup --send-alert
```

Confirm the test email arrives. Log in as the owner, create an ordinary member
over SSH, and verify messaging and a 10 MB attachment between two browsers.
The member command prompts for its password:

```bash
(
  cd /tmp
  sudo -u chatto /usr/local/bin/chatto operator \
    --config /etc/chatto/chatto.toml \
    --operator-socket /run/chatto/operator.sock \
    user create \
    --login MEMBER_LOGIN \
    --display-name "Member Name"
)
```

Before accepting a $5/512 MB instance for production, sustain that browser
workload and run the 15-minute capacity gate:

```bash
sudo ./verify-deployment.sh --capacity
```

If every threshold passes, continue to the recovery qualification. If any
threshold fails, do not accept the host for production; follow the replacement
procedure below.

## 6. If capacity fails, replace the instance with the $7 bundle

Lightsail does not resize an existing instance in place. It creates a new,
larger instance from a snapshot. Keep public TCP 22 open throughout this
replacement:

1. Run and verify one final backup, stop the backup timer, then shut down the
   source instance cleanly:

   ```bash
   sudo systemctl start chatto-backup.service
   sudo ./verify-deployment.sh
   sudo systemctl stop chatto-backup.timer
   sudo shutdown -h now
   ```

2. In Lightsail, create a manual snapshot of the stopped instance. Create a new
   instance from that snapshot using the $7/1 GB public-IPv4 bundle in the same
   region.
3. Apply the bootstrap firewall rules to the new instance. Firewall settings
   belong to the instance and must be checked explicitly.
4. Keep the original instance stopped. The snapshot contains the same
   Tailscale machine identity, so never run the original and replacement
   concurrently.
5. Detach the static IPv4 address from the original instance and attach it to
   the replacement. DNS then remains unchanged.
6. Connect to the replacement, confirm the backup and reboot timers are active,
   and rerun the live verification, browser workload, and capacity gate:

   ```bash
   cd chatto-on-lightsail
   sudo ./verify-deployment.sh --run-backup --send-alert
   sudo ./verify-deployment.sh --capacity
   ```

7. Keep the original instance and snapshot until the replacement passes every
   acceptance check. Delete the old instance only after the replacement is
   accepted; retain or delete the snapshot according to the recovery policy.

AWS documents the underlying
[snapshot-based Lightsail upsize workflow](https://docs.aws.amazon.com/lightsail/latest/userguide/how-to-create-larger-instance-from-snapshot-using-console.html).

## 7. Qualify recovery before production

Do not mark the deployment production-ready until the complete
[Disposable Instance Qualification](chatto-lightsail-plan.md#disposable-instance-qualification)
has passed on a fresh Debian 13 instance. It deliberately exercises failure
paths that should not be introduced on the intended production host:

- Interrupted and resumed base preparation.
- Repeated backups and local-retention behavior.
- Direct and forced-failure SNS alerts.
- Security-only unattended-upgrade selection.
- The complete browser and capacity workload.
- Download, checksum verification, restore, and owner/member validation.
- Tailnet SSH, public-port closure, and break-glass reopening.

Use a fresh Tailscale auth key for the disposable host. Delete its Tailscale
node after the rehearsal, and save the qualification results with the
deployment record. Repeat a restore rehearsal quarterly after production
acceptance.

## 8. Move SSH onto the tailnet

Only after the production host verification and disposable qualification pass,
open a **new** terminal on the workstation while keeping the existing
public-IP session connected, and confirm SSH over the tailnet:

```bash
ssh admin@chatto
```

Use `ssh admin@TAILNET_IP` with the address printed by the verification if
MagicDNS is disabled. Once that session works, remove TCP 22 from **both** the
IPv4 and the IPv6 Lightsail firewalls, confirm `ssh admin@LIGHTSAIL_IP` now
times out, and test break-glass access once. Runbook section 7 has the full
procedure, the exact firewall command, failure modes, and rollback.

## Reruns and recovery

- `install-host.sh prepare` may be rerun safely after a partial base setup.
- `install-host.sh install` preserves existing Chatto secrets, AWS
  credentials, the backup passphrase, and the recorded owner.
- `install-host.sh install` skips Tailscale enrollment while the node is
  already `Running`; a fresh enrollment always needs a newly minted auth key.
- If the tailnet is ever unreachable after public TCP 22 was closed, re-add
  TCP 22 restricted to the operator's IP through the Lightsail console or CLI
  (break-glass), then repair Tailscale over plain SSH.
- `provision-aws.sh` reconciles resource controls but refuses unexpected IAM
  policies, console access, extra keys, or a mismatched AWS account.
- Neither installer upgrades or downgrades an existing different Chatto
  version. Use the runbook's verified backup and manual upgrade procedure.
- A true recovery also needs the password-manager copies of
  `/etc/chatto/chatto.toml`, `/etc/chatto/chatto.env`, and the backup
  passphrase.
