# Chatto on Lightsail

[Chatto](https://docs.chatto.run) is a self-hosted community chat server that
runs as a single Go binary with embedded NATS/JetStream. This repository
deploys a private, low-resource Chatto instance — pinned to the qualified
`v0.4.14` release — onto a Debian 13 AWS Lightsail VM, with S3 backups, SNS
alerts, SES transactional email, and administrative SSH over Tailscale.

The primary audience is the human operator responsible for the AWS account,
DNS, credentials, recovery material, and production acceptance. The scripts
automate repeatable mechanics and stop at human security boundaries. The
complete architecture, manual fallback, operational procedures, and acceptance
rationale are in [`chatto-lightsail-plan.md`](chatto-lightsail-plan.md).

Throughout this README, **operator workstation** means your Mac. **Lightsail
host**, **instance**, and **server** mean the remote Debian 13 VM.

Resuming a paused deployment? Run `./check-deployment-progress.sh`: it is
read-only, reports which workstation artifacts already exist, and names the
next step.

## Contents

- Before installation
  - [A. Install and verify the operator tools](#a-install-and-verify-the-operator-tools)
  - [B. Authenticate the personal-account operator](#b-authenticate-the-personal-account-operator)
  - [C. Create the Lightsail instance and record its values](#c-create-the-lightsail-instance-and-record-its-values)
  - [D. Lock down both Lightsail firewalls for bootstrap](#d-lock-down-both-lightsail-firewalls-for-bootstrap)
  - [E. Prepare Tailscale](#e-prepare-tailscale)
  - [F. Complete the deployment input](#f-complete-the-deployment-input)
  - [G. Store the human-generated secrets](#g-store-the-human-generated-secrets)
- [Repository preflight](#repository-preflight)
- [1. Provision AWS](#1-provision-aws)
- [2. Transfer the host installer](#2-transfer-the-host-installer)
- [3. Prepare and reboot the host](#3-prepare-and-reboot-the-host)
- [4. Preserve recovery material and remove temporary secrets](#4-preserve-recovery-material-and-remove-temporary-secrets)
- [5. Verify the deployment](#5-verify-the-deployment)
- [6. If capacity fails, replace the instance with the $7 bundle](#6-if-capacity-fails-replace-the-instance-with-the-7-bundle)
- [7. Qualify recovery before production](#7-qualify-recovery-before-production)
- [8. Move SSH onto the tailnet](#8-move-ssh-onto-the-tailnet)
- [Reruns and recovery](#reruns-and-recovery)
- [General admin tasks](#general-admin-tasks)

## Before installation

Complete these steps in order. Run all workstation commands from the
repository root. Repository scripts select Bash through their own shebang and
behave the same from any interactive shell; run the remaining multi-line
command blocks in Bash, since they are written and tested for it.

Plan for external waits: [section 1](#1-provision-aws) stops for SNS email
confirmation, SES DKIM verification, and SES production-access approval, and
the last of those can take AWS up to a business day to grant.

### A. Install and verify the operator tools

The operator workstation requires Bash, AWS CLI v2.32 or newer, Python 3,
`jq`, ShellCheck, `curl`, `tar`, OpenSSH (`ssh` and `scp`), `dig`, and the
standard `grep`, `mktemp`, `sed`, and `stat` utilities. Python derives the
region-specific SES SMTP password without exposing the AWS secret key in a
process argument. ShellCheck is a required repository preflight.

Install Python, `jq`, and ShellCheck with Homebrew, then install AWS CLI v2
from the official AWS package:

```bash
(
  set -euo pipefail
  brew install jq shellcheck python
  aws_cli_tmp=$(mktemp -d)
  curl -fLo "${aws_cli_tmp}/AWSCLIV2.pkg" \
    https://awscli.amazonaws.com/AWSCLIV2.pkg
  sudo installer -pkg "${aws_cli_tmp}/AWSCLIV2.pkg" -target /
  rm -rf -- "${aws_cli_tmp}"
)
```

AWS publishes installer details and signature-verification instructions in its
[AWS CLI v2 installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).

Run this gate after installation. Do not continue if it reports a missing
tool or an AWS CLI older than v2.32:

```bash
./check-operator-tools.sh
```

### B. Authenticate the personal-account operator

This deployment uses a dedicated `chatto-operator` IAM user in the personal
AWS account. The operator must be allowed to create and configure S3, SNS,
SES, and IAM resources, including the restricted IAM users and access keys
used by the Lightsail host. Use browser-backed temporary credentials and do
not create a long-lived access key for `chatto-operator`. Do not use the
`chatto-backup` runtime identity, and never create root-user access keys.

1. Sign in to the AWS Management Console with an existing administrator. If
   the root user is the account's only identity, use it only for this initial
   administrator setup, ensure root MFA is enabled, and sign it out afterward.
2. Open **IAM → Users → Create user**. Name the user `chatto-operator`, enable
   AWS Management Console access, and assign a unique password.
3. Attach the AWS-managed `AdministratorAccess` and
   `SignInLocalDevelopmentAccess` policies. The first permits this deployment's
   provisioning work; the second permits browser-backed AWS CLI login.
4. Open the new user's **Security credentials** tab. Under
   **Multi-factor authentication (MFA)**, choose **Assign MFA device** and
   enroll a passkey, security key, or authenticator application.
5. Sign out of the bootstrap administrator or root session and sign in as
   `chatto-operator`. Complete the MFA challenge before continuing.
6. On the Mac, run the command below. Enter the planned Lightsail Region when
   prompted and select the `chatto-operator` browser session:

```bash
aws login --profile chatto-admin
```

`aws login` stores refreshable temporary credentials rather than an IAM access
key. The session lasts for at most 12 hours; rerun the command when it expires.
See AWS's
[browser-backed CLI login guide](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
for details.

#### Verify the operator profile

Select and verify the profile:

```bash
export AWS_PROFILE=chatto-admin
aws sts get-caller-identity \
  --query '{Account:Account,Arn:Arn}' \
  --output table
```

Read the account ID and ARN in the output and confirm that they identify the
intended AWS account and the `chatto-operator` IAM user. Stop on an unexpected
account, an ARN containing `root`, or any other unexpected identity. Set
`AWS_PROFILE=chatto-admin` again in each new workstation shell used for this
deployment.

### C. Create the Lightsail instance and record its values

Print the workstation's current public IPv4 address and confirm it is the
expected network (no VPN or proxy in the path). The firewall step fetches
this address itself; this check is to catch a wrong egress path early:

```bash
curl -4 -fsS https://checkip.amazonaws.com
```

In the Lightsail console:

1. Select the deployment region, and use that same region in every later
   Lightsail and provisioning command.
2. Create a Linux/Unix instance using the **OS Only / Debian 13** blueprint.
3. Select the $5 public-IPv4 bundle to evaluate the lowest-cost option, or
   start with the $7/1 GB bundle to avoid a snapshot-based replacement if the
   later capacity gate rejects the $5 bundle.
4. Name the instance and wait for it to reach `Running`.
5. Create a Lightsail static IPv4 address in the same region and attach it to
   the instance.
6. Create an `A` record for the chat hostname pointing to that static IPv4
   address.

Record the results in the deployment input file. Later steps read this file
instead of asking for hand-copied placeholder values:

```bash
cp chatto-deploy.env.example chatto-deploy.env
chmod 0600 chatto-deploy.env
```

Edit `chatto-deploy.env` and set at least `CHAT_HOST`,
`LIGHTSAIL_INSTANCE_NAME`, `LIGHTSAIL_STATIC_IP`, and `CHATTO_AWS_REGION` to
the values just created. Do not add shell quotes: values are read literally,
without shell evaluation. [Step F](#f-complete-the-deployment-input) completes
the remaining values.

Verify the instance and DNS using the recorded values. The instance output
must show `running`, the Debian 13 blueprint, the intended bundle, and the
attached static IPv4 address. The `A` lookup must return exactly the recorded
static IPv4 address.

```bash
(
  set -euo pipefail
  region=$(./deployment-value.sh CHATTO_AWS_REGION)
  instance=$(./deployment-value.sh LIGHTSAIL_INSTANCE_NAME)
  chat_host=$(./deployment-value.sh CHAT_HOST)
  aws lightsail get-instance \
    --region "${region}" \
    --instance-name "${instance}" \
    --query \
      'instance.{State:state.name,Blueprint:blueprintName,Bundle:bundleId,PublicIPv4:publicIpAddress}' \
    --output table
  aws lightsail get-static-ips --region "${region}" --output table
  dig +short "${chat_host}" A
  dig +short "${chat_host}" AAAA
)
```

The `AAAA` result must be empty unless IPv6 was deliberately enabled and the
hostname was deliberately pointed at this instance's public IPv6 address.

### D. Lock down both Lightsail firewalls for bootstrap

The instance must end up with exactly three inbound rules:

- TCP 80 from `0.0.0.0/0`.
- TCP 443 from `0.0.0.0/0`.
- TCP 22 from the operator's current public IPv4 address as a `/32`.

TCP 80 and 443 must be open to the entire internet before the install phase
runs: Chatto obtains and renews its Let's Encrypt certificate through them,
and while either port is blocked, issuance fails and every HTTPS request —
including the later verification step — is refused with a
`tlsv1 alert internal error`.

Apply the rules from the workstation. `put-instance-public-ports` replaces
the instance's entire inbound rule set with exactly the rules given, so this
single command removes the Lightsail defaults and installs the three rules
above in one step:

```bash
(
  set -euo pipefail
  region=$(./deployment-value.sh CHATTO_AWS_REGION)
  instance=$(./deployment-value.sh LIGHTSAIL_INSTANCE_NAME)
  operator_ip=$(curl -4 -fsS https://checkip.amazonaws.com)
  aws lightsail put-instance-public-ports \
    --region "${region}" \
    --instance-name "${instance}" \
    --port-infos \
      'fromPort=80,toPort=80,protocol=TCP,cidrs=0.0.0.0/0' \
      'fromPort=443,toPort=443,protocol=TCP,cidrs=0.0.0.0/0' \
      "fromPort=22,toPort=22,protocol=TCP,cidrs=${operator_ip}/32"
)
```

The command grants nothing over IPv6, which is correct for the default
IPv4-only deployment. If IPv6 was deliberately enabled, add matching
`ipv6Cidrs` entries — `::/0` for TCP 80 and 443, and the operator's public
IPv6 address as a `/128` for TCP 22 — or disable IPv6 if TCP 22 cannot be
restricted. If the operator's public IP changes before installation, rerun
the command to update the TCP 22 rule before reconnecting.

Inspect the effective rules from the workstation:

```bash
(
  set -euo pipefail
  aws lightsail get-instance-port-states \
    --region "$(./deployment-value.sh CHATTO_AWS_REGION)" \
    --instance-name "$(./deployment-value.sh LIGHTSAIL_INSTANCE_NAME)" \
    --output json |
    jq '.portStates | map({
      protocol, fromPort, toPort, cidrs, ipv6Cidrs, cidrListAliases
    })'
)
```

Do not continue until the output matches the rules above. TCP 22 is
temporary: administrative SSH moves onto the tailnet, and the final
SSH-lockdown step ([section 8](#8-move-ssh-onto-the-tailnet)) removes public
TCP 22 from both firewalls.

### E. Prepare Tailscale

Use a Tailscale account whose workstation and other operator devices are
already enrolled. Add `tag:chatto` to the tailnet policy file. `tagOwners`
controls who may apply the tag; it does not grant network access. Add a grant
that permits the intended operator identity or group to reach TCP 22 on the
tagged server. For an administrator-only setup:

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

In the admin console, create an auth key with all of these properties:
pre-authorized, **not** reusable, not ephemeral, and tagged `tag:chatto`. Save
it with the repository script, which prompts without echoing and keeps the key
out of shell history:

```bash
./save-tailscale-authkey.sh
```

### F. Complete the deployment input

Fill in the rest of the `chatto-deploy.env` file created in
[step C](#c-create-the-lightsail-instance-and-record-its-values). Choose a
globally unique S3 bucket name, set the owner and email addresses, and leave
`CHATTO_AWS_ACCOUNT_ID` and `CHATTO_SNS_TOPIC_ARN` blank: provisioning fills
those generated values. Keep `CHATTO_SES_DOMAIN` and `CHATTO_SMTP_FROM` as
the example file records them for this deployment; the sender must be an
address directly below the configured SES domain.

Before continuing, inspect every line and make sure none of the example
addresses or placeholder values remains:

```bash
if grep -nE 'example\.com|operator@example\.com|replace-with' \
  chatto-deploy.env; then
  echo "Replace every example value before continuing" >&2
  false
else
  echo "Deployment input contains no example placeholders"
fi
```

### G. Store the human-generated secrets

Create and save a random backup passphrase of at least 24 characters and a
strong owner password in the external password manager before running the host
installation. The installer prompts for both without placing either value in
shell history.

## Repository preflight

Run these portable checks from the repository root before provisioning or
copying artifacts:

```bash
(
  set -euo pipefail
  tests/operator-workflow-test.sh
  bash -n \
    chatto-operator-lib.sh provision-aws.sh install-host.sh \
    verify-deployment.sh check-operator-tools.sh \
    check-deployment-progress.sh deployment-value.sh \
    save-tailscale-authkey.sh chatto-lightsail-*.sh
  shellcheck -x \
    chatto-operator-lib.sh provision-aws.sh install-host.sh \
    verify-deployment.sh check-operator-tools.sh \
    check-deployment-progress.sh deployment-value.sh \
    save-tailscale-authkey.sh chatto-lightsail-*.sh tests/*.sh
)
```

All three commands are required and must exit successfully. Do not provision
AWS resources or copy artifacts to the host after a failed check.

`systemd-analyze` is not normally available on macOS. The host installer
validates every installed unit with `systemd-analyze verify` on Debian before
starting the services.

## 1. Provision AWS

Run from the operator workstation:

```bash
chmod +x provision-aws.sh
./provision-aws.sh \
  --env chatto-deploy.env \
  --output chatto-provisioned.env \
  --access-key-output chatto-access-key.env \
  --smtp-credentials-output chatto-smtp-credentials.env
```

The command creates and verifies the S3 bucket controls, SNS topic, SES domain
identity, and restricted `chatto-backup` and `chatto-smtp` IAM users. It
writes:

- `chatto-provisioned.env`: non-secret, normalized deployment inputs.
- `chatto-access-key.env`: the one-time runtime access key, mode `0600`.
- `chatto-smtp-credentials.env`: the regional SMTP username and derived
  password, mode `0600`, once SES is ready.

The first run normally stops while SNS confirmation and SES domain
verification are pending; these waits are external, so expect this section to
span more than one sitting. Confirm the SNS subscription from the email AWS
sends (usually within minutes). Add each CNAME printed under
`Publish these CNAME records` to the DNS zone for the configured
`CHATTO_SES_DOMAIN`; do not alter the record names or targets. Easy DKIM
usually reports `Verified` within an hour of DNS publication. In the SES
console for `CHATTO_AWS_REGION`, request production access so Chatto can send
to recipients that are not separately verified SES identities; that approval
is human-reviewed and can take up to a business day. Production access is not
required to create the SMTP credential: the script warns while the account is
still in the sandbox, where SES only delivers to separately verified
identities, and the same credential works unchanged once approval lands.

After SNS is confirmed and Easy DKIM reports `Verified`, rerun the same
command; production access can still be pending. Reruns are safe: the script
reports and keeps any credential it already captured, never overwrites a
credential output, and AWS cannot recover either access-key secret. Store
both credential files in the password manager.

## 2. Transfer the host installer

**On the workstation**, build a fixed-manifest archive containing only
host-side artifacts, then copy it and the deployment inputs to the recorded
static IP and connect:

```bash
(
  set -euo pipefail
  tar -czf /tmp/chatto-host-installer.tgz -T host-installer-files.txt
  lightsail_ip=$(./deployment-value.sh LIGHTSAIL_STATIC_IP)
  scp \
    /tmp/chatto-host-installer.tgz \
    chatto-provisioned.env \
    chatto-access-key.env \
    chatto-smtp-credentials.env \
    chatto-tailscale-authkey.env \
    chatto:
  ssh chatto
)
```

The Debian Lightsail image normally uses `admin` as its SSH user. Use the
actual blueprint user if it differs.

**On the Lightsail host**, in the SSH session the last command opened, unpack
the installer:

```bash
mkdir -p chatto-on-lightsail
tar -xzf chatto-host-installer.tgz -C chatto-on-lightsail
mv chatto-provisioned.env chatto-access-key.env \
  chatto-smtp-credentials.env \
  chatto-tailscale-authkey.env chatto-on-lightsail/
cd chatto-on-lightsail
chmod +x install-host.sh verify-deployment.sh
```

## 3. Prepare and reboot the host

**On the Lightsail host**, still in that SSH session:

```bash
sudo ./install-host.sh prepare
sudo reboot
```

The prepare phase is idempotent. It configures the 1 GiB swap file, installs
base packages, upgrades Debian, and creates the locked-down `chatto` service
account. It deliberately does not hide the required reboot.

**On the workstation**, reconnect after the instance returns:

```bash
ssh "admin@$(./deployment-value.sh LIGHTSAIL_STATIC_IP)"
```

**On the Lightsail host**, run the install phase:

```bash
cd chatto-on-lightsail
sudo ./install-host.sh install \
  --env chatto-provisioned.env \
  --credentials chatto-access-key.env \
  --smtp-credentials chatto-smtp-credentials.env \
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
- Installs the SES SMTP credential in `/etc/chatto/smtp.env` with mode `0600`
  and configures mandatory STARTTLS to the regional SES endpoint.
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
ssh chatto \
  'sudo tar -C /etc/chatto -czf - chatto.toml chatto.env smtp.env' \
  > chatto-recovery-config.tgz
chmod 0600 chatto-recovery-config.tgz
tar -tzf chatto-recovery-config.tgz
```

Store that archive in the external password manager together with:

- The owner password and backup passphrase.
- The `chatto-backup` access key ID and secret.
- The `chatto-smtp` SMTP username and derived SMTP password.
- The non-secret `chatto-provisioned.env` deployment record.

Require the password-manager copies to be readable before deleting any
temporary file. In the original server terminal, remove the transferred
credential and auth-key inputs. The installed AWS copy remains protected at
`/etc/chatto/aws/credentials`, and the consumed Tailscale auth key is
single-use:

```bash
rm chatto-access-key.env chatto-smtp-credentials.env \
  chatto-tailscale-authkey.env
```

On the workstation, remove the temporary secret files after confirming their
password-manager copies:

```bash
rm chatto-access-key.env \
  chatto-smtp-credentials.env \
  chatto-tailscale-authkey.env \
  chatto-recovery-config.tgz
```

The auth key needs no retained copy: a future re-enrollment uses a freshly
minted key.

## 5. Verify the deployment

**On the Lightsail host**, run the live backup and alert paths:

```bash
sudo ./verify-deployment.sh --run-backup --send-alert
```

Confirm the SNS test alert arrives. Log in as the owner, add an email address
from account settings, and confirm that the Chatto verification message
arrives from the configured `CHATTO_SMTP_FROM` sender. Complete the code
challenge, then exercise
password recovery and confirm the received message passes DKIM. Public
registration must remain unavailable.

Create an ordinary member over SSH, then verify messaging and a 10 MB
attachment between two browsers. The member command prompts for its password:

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

If every threshold passes, continue to the recovery qualification
([section 7](#7-qualify-recovery-before-production)). If any threshold fails,
do not accept the host for production; follow the replacement procedure in
[section 6](#6-if-capacity-fails-replace-the-instance-with-the-7-bundle).

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
keep the existing public-IP session connected and read the host's tailnet
IPv4 address from the `Tailnet address` line that `verify-deployment.sh`
printed (or run `tailscale ip -4` on the host).

Test with that literal `100.x.y.z` address, not a name. A `Host chatto` alias
in the workstation's `~/.ssh/config` — or any entry pointing at the public
hostname or IP — shadows the MagicDNS name `chatto`, so `ssh admin@chatto`
can silently connect over the public path, appear to prove tailnet access,
and then lock the operator out when public TCP 22 closes. The literal address
cannot ride the wrong path.

**On the workstation**, open a **new** terminal and confirm SSH over the
tailnet, replacing `TAILNET_IPV4` with the address read above:

```bash
ssh admin@TAILNET_IPV4
```

Once that session works, remove TCP 22 from **both** the IPv4 and the IPv6
Lightsail firewalls. As in [section D](#d-lock-down-both-lightsail-firewalls-for-bootstrap),
`put-instance-public-ports` replaces the whole inbound rule set, so listing
only the web ports drops TCP 22 from both address families in one step:

```bash
(
  set -euo pipefail
  aws lightsail put-instance-public-ports \
    --region "$(./deployment-value.sh CHATTO_AWS_REGION)" \
    --instance-name "$(./deployment-value.sh LIGHTSAIL_INSTANCE_NAME)" \
    --port-infos \
      'fromPort=80,toPort=80,protocol=TCP,cidrs=0.0.0.0/0' \
      'fromPort=443,toPort=443,protocol=TCP,cidrs=0.0.0.0/0'
)
```

If IPv6 was deliberately enabled, keep the `ipv6Cidrs=::/0` entries for TCP
80 and 443 from section D while omitting the TCP 22 rule. Confirm that a
public-IP connection
(`ssh "admin@$(./deployment-value.sh LIGHTSAIL_STATIC_IP)"`) now times out,
and test break-glass access once. Afterward, the MagicDNS name is fine for daily use —
first run `ssh -G chatto` and confirm its `hostname` line shows the tailnet
address rather than an alias target. Runbook
[section 7](chatto-lightsail-plan.md#7-private-administrative-access-over-tailscale)
has the full procedure, the exact firewall command, failure modes, and
rollback.

## Reruns and recovery

- `install-host.sh prepare` may be rerun safely after a partial base setup.
- `install-host.sh install` preserves existing Chatto secrets, AWS
  credentials, SES SMTP credentials, the backup passphrase, and the recorded
  owner.
- `install-host.sh install` skips Tailscale enrollment while the node is
  already `Running`; a fresh enrollment always needs a newly minted auth key.
- If the tailnet is ever unreachable after public TCP 22 was closed, re-add
  TCP 22 restricted to the operator's IP through the Lightsail console or CLI
  (break-glass), then repair Tailscale over plain SSH.
- `provision-aws.sh` reconciles resource controls but refuses unexpected IAM
  policies, console access, extra keys, or a mismatched AWS account.
- `provision-aws.sh` reruns keep already-captured credential outputs
  unchanged; it stops only when an access key exists without its captured
  file, because AWS cannot recover the secret.
- Neither installer upgrades or downgrades an existing different Chatto
  version. Use the runbook's verified backup and manual upgrade procedure.
- A true recovery also needs the password-manager copies of
  `/etc/chatto/chatto.toml`, `/etc/chatto/chatto.env`,
  `/etc/chatto/smtp.env`, and the backup passphrase.

## General admin tasks

### Create a user

**On the Lightsail host**, create the account with the operator CLI. Run it as
the `chatto` service account so file ownership stays consistent, and pass the
operator socket explicitly: the CLI defaults to `/tmp/chatto/operator.sock`,
but this deployment serves the socket at `/run/chatto/operator.sock` (and the
service's `PrivateTmp=true` hides its private `/tmp` anyway). Generate a
password for the new account and store it in the password manager:

```bash
openssl rand -base64 24
```

The create command prompts for the password; paste the generated value at the
prompt so it never lands in shell history:

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

Do not pass `--role owner` unless deliberately creating another owner-level
account. Public registration stays disabled and `max_users = 10` caps the
account count, so operator creation is the only path. Confirm the account
exists:

```bash
(
  cd /tmp
  sudo -u chatto /usr/local/bin/chatto operator \
    --config /etc/chatto/chatto.toml \
    --operator-socket /run/chatto/operator.sock \
    user list --search MEMBER_LOGIN
)
```

If the create command fails with `dial unix ... no such file or directory`,
the server is not running; check `systemctl status chatto`. The socket exists
only while the service is up.

### Upgrade Chatto (unconfirmed)

> **Status: unconfirmed.** The step list comes from the runbook's
> "Security Updates and Manual Upgrades" section in `chatto-lightsail-plan.md`;
> the concrete commands below mirror `install-host.sh`'s checksum-verified
> install but have not been exercised end to end. Validate this procedure
> during the next real upgrade, fix what differs, and remove this notice.

Neither installer upgrades an existing different Chatto version, and the
operator library refuses any `CHATTO_VERSION` other than the qualified
release. Upgrading therefore has a repository half and a host half.

**In this repository**, read the release notes for every release between the
current pin and the target — pre-1.0 Chatto makes no compatibility promises —
then move the pin to the new explicit target in all five places (never a
latest-release lookup):

- `chatto-operator-lib.sh` — the `CHATTO_VERSION must remain pinned`
  enforcement check
- `chatto-deploy.env` and `chatto-provisioned.env` — the recorded target
- `chatto-deploy.env.example` and `tests/operator-workflow-test.sh` — keep
  documentation and tests consistent

**On the Lightsail host**, run the maintenance window. Stop the backup timer
first: `chatto-backup.service` declares `Requires=chatto.service`, so a timer
firing mid-upgrade would silently restart a deliberately stopped Chatto.

```bash
sudo systemctl stop chatto-backup.timer
sudo systemctl start chatto-backup.service
systemctl status chatto-backup.service
```

Require the backup to report a successful checksum-verified S3 upload before
continuing. Then download and checksum-verify the exact target version
(substitute `arm64` for `x86_64` if `uname -m` reports `aarch64`):

```bash
CHATTO_VERSION=v0.x.y
cd "$(mktemp -d /var/tmp/chatto-upgrade.XXXXXX)"
curl -fsSLO "https://github.com/chattocorp/chatto/releases/download/${CHATTO_VERSION}/chatto_Linux_x86_64.tar.gz"
curl -fsSLO "https://github.com/chattocorp/chatto/releases/download/${CHATTO_VERSION}/chatto_${CHATTO_VERSION#v}_checksums.txt"
grep "  chatto_Linux_x86_64.tar.gz\$" \
  "chatto_${CHATTO_VERSION#v}_checksums.txt" | sha256sum --check -
tar -xzf chatto_Linux_x86_64.tar.gz
```

Swap the binary, preserving the old one for rollback:

```bash
sudo systemctl stop chatto
sudo cp -a /usr/local/bin/chatto /usr/local/bin/chatto.previous
sudo install -o root -g root -m 0755 chatto /usr/local/bin/chatto
sudo systemctl start chatto
```

Check readiness, login, logs, and memory:

```bash
/usr/local/bin/chatto version
systemctl status chatto
journalctl -u chatto -e
```

If startup or compatibility checks fail, roll back and investigate before
retrying:

```bash
sudo systemctl stop chatto
sudo install -o root -g root -m 0755 \
  /usr/local/bin/chatto.previous /usr/local/bin/chatto
sudo systemctl start chatto
```

Finally, restart the backup timer, confirm it is scheduled, and rerun the
deployment verification (which asserts the installed binary matches the
updated `CHATTO_VERSION` pin):

```bash
sudo systemctl start chatto-backup.timer
systemctl list-timers chatto-backup.timer
sudo ./verify-deployment.sh
```

## License

Released under the [MIT License](LICENSE).
