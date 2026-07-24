# Chatto on Lightsail

This repository installs a private, low-resource Chatto deployment on an
existing Debian 13 Lightsail instance. The primary audience is the human
operator responsible for the AWS account, DNS, credentials, recovery material,
and production acceptance. The scripts automate repeatable mechanics and stop
at human security boundaries.

The deployment remains pinned to Chatto `v0.4.14`. The complete architecture,
manual fallback, operational procedures, and acceptance rationale are in
[`chatto-lightsail-plan.md`](chatto-lightsail-plan.md).

Throughout this README, **operator workstation** means your Mac. **Lightsail
host**, **instance**, and **server** mean the remote Debian 13 VM.

## Before installation

Complete these steps in order. Run all workstation commands in Bash from the
repository root.

### 1. Install and verify the operator tools

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

Run this gate after installation. Do not continue if a command is missing or
if AWS CLI is older than v2.32:

```bash
(
  set -euo pipefail
  for tool in \
    bash aws python3 jq shellcheck curl tar ssh scp dig grep mktemp sed stat; do
    command -v "${tool}" >/dev/null 2>&1 || {
      echo "Missing required operator tool: ${tool}" >&2
      exit 1
    }
  done

  aws_version=$(aws --version 2>&1)
  if [[ ! "${aws_version}" =~ ^aws-cli/2\.([0-9]+)\. ]] ||
    ((BASH_REMATCH[1] < 32)); then
    echo "AWS CLI v2.32 or newer is required; found: ${aws_version}" >&2
    exit 1
  fi
  printf '%s\n' "${aws_version}"
  jq --version
  shellcheck --version
)
```

### 2. Authenticate your AWS administrator profile

Use temporary credentials for a human administrator. The administrator must be
allowed to create and configure S3, SNS, SES, and IAM resources, including the
restricted IAM user and access key used by the Lightsail host. Do not use the
`chatto-backup` runtime identity, and never create root-user access keys.

Choose the path that matches the AWS account.

#### Account already uses IAM Identity Center

Confirm in the IAM Identity Center console that your user is assigned to the
target AWS account with an administrator permission set. The permission set
must permit IAM administration as well as S3, SNS, and SES administration;
`AdministratorAccess` satisfies this deployment. Record the AWS access portal
URL and the Region where IAM Identity Center is configured, then run:

```bash
aws configure sso --profile chatto-admin
aws sso login --profile chatto-admin
```

In the configuration wizard:

- Use `chatto-admin` as the SSO session name.
- Enter the access portal URL and IAM Identity Center Region exactly as shown
  in the IAM Identity Center console. This Region can differ from the
  Lightsail Region.
- Select the intended AWS account and its administrator role.
- Set the default client Region to the planned Lightsail Region and the output
  format to `json`.

See AWS's
[IAM Identity Center CLI configuration](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html)
for the corresponding console and wizard fields.

#### Personal account without IAM Identity Center

Create a dedicated `chatto-operator` IAM user and use browser-backed temporary
credentials. Do not create a long-lived access key for this user:

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

#### Verify either profile

After completing either authentication path, select and verify the profile:

```bash
export AWS_PROFILE=chatto-admin
aws sts get-caller-identity \
  --query '{Account:Account,Arn:Arn}' \
  --output table
```

Read the account ID and ARN in the output and confirm that they identify the
intended AWS account and administrator user or role. Stop on an unexpected
account, an ARN containing `root`, or any other unexpected identity. Set
`AWS_PROFILE=chatto-admin` again in each new workstation shell used for this
deployment.

### 3. Create and verify the Lightsail instance and DNS

Record the AWS account ID, Lightsail region, instance name, static IPv4
address, chat hostname, and the operator's current public IP before continuing.
Use the same region in every Lightsail and provisioning command.

Print the workstation's current public IPv4 address with:

```bash
curl -4 -fsS https://checkip.amazonaws.com
```

In the Lightsail console:

1. Select the deployment region.
2. Create a Linux/Unix instance using the **OS Only / Debian 13** blueprint.
3. Select the $5 public-IPv4 bundle to evaluate the lowest-cost option, or
   start with the $7/1 GB bundle to avoid a snapshot-based replacement if the
   later capacity gate rejects the $5 bundle.
4. Give the instance its recorded name and wait for it to reach `Running`.
5. Create a Lightsail static IPv4 address in the same region and attach it to
   the instance.
6. Create an `A` record for the chat hostname pointing to that static IPv4
   address.

Replace all `REPLACE_WITH_...` values below, then verify the instance and DNS.
The instance output must show `running`, the Debian 13 blueprint, the intended
bundle, and the attached static IPv4 address. The DNS command must return that
same static IPv4 address.

```bash
aws lightsail get-instance \
  --region REPLACE_WITH_REGION \
  --instance-name REPLACE_WITH_INSTANCE_NAME \
  --query \
    'instance.{State:state.name,Blueprint:blueprintName,Bundle:bundleId,PublicIPv4:publicIpAddress}' \
  --output table

aws lightsail get-static-ips \
  --region REPLACE_WITH_REGION \
  --output table

dig +short REPLACE_WITH_CHAT_HOST A
dig +short REPLACE_WITH_CHAT_HOST AAAA
```

The `AAAA` result must be empty unless IPv6 was deliberately enabled and the
hostname was deliberately pointed at this instance's public IPv6 address.

### 4. Lock down both Lightsail firewalls for bootstrap

In the instance's **Networking** tab, remove the default inbound rules and
configure the IPv4 firewall with only:

- TCP 80 from `0.0.0.0/0`.
- TCP 443 from `0.0.0.0/0`.
- TCP 22 from the operator's current public IPv4 address as a `/32`.

If IPv6 is enabled, configure the separate IPv6 firewall with the equivalent
rules: TCP 80 and 443 from `::/0`, and TCP 22 only from the operator's public
IPv6 address as a `/128`. If TCP 22 cannot be restricted on IPv6, disable IPv6
instead. Do not leave any other inbound ports open. If the operator's public IP
changes before installation, update the TCP 22 rule before reconnecting.

Inspect the effective rules from the workstation:

```bash
aws lightsail get-instance-port-states \
  --region REPLACE_WITH_REGION \
  --instance-name REPLACE_WITH_INSTANCE_NAME \
  --output json |
  jq '.portStates | map({
    protocol, fromPort, toPort, cidrs, ipv6Cidrs, cidrListAliases
  })'
```

Do not continue until the output matches the rules above. TCP 22 is temporary:
administrative SSH moves onto the tailnet, and the final SSH-lockdown step
removes public TCP 22 from both firewalls.

### 5. Prepare Tailscale

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
it without putting the key in shell history:

```bash
(
  set -euo pipefail
  umask 077
  read -r -s -p 'Tailscale auth key: ' TS_AUTHKEY
  printf '\n'
  [[ "${TS_AUTHKEY}" == tskey-auth-* ]] || {
    echo "The value does not look like a Tailscale auth key" >&2
    exit 1
  }
  printf 'TS_AUTHKEY=%s\n' "${TS_AUTHKEY}" \
    > chatto-tailscale-authkey.env
)
test -s chatto-tailscale-authkey.env
```

### 6. Create the literal deployment input

Copy and edit the literal deployment input file:

```bash
cp chatto-deploy.env.example chatto-deploy.env
chmod 0600 chatto-deploy.env
```

Do not add shell quotes. Values are read literally, without shell evaluation.
Set `CHATTO_AWS_REGION` to the region containing the Lightsail instance, choose
a globally unique S3 bucket name, and leave `CHATTO_AWS_ACCOUNT_ID` and
`CHATTO_SNS_TOPIC_ARN` blank: provisioning fills those generated values.
Set `CHATTO_SES_DOMAIN=jessedc.dev` and
`CHATTO_SMTP_FROM=noreply@jessedc.dev`; the sender must be directly below the
configured SES domain.

Before continuing, inspect every line and make sure none of the example
addresses or placeholder bucket name remains:

```bash
if grep -nE 'example\.com|operator@example\.com|replace-with' \
  chatto-deploy.env; then
  echo "Replace every example value before continuing" >&2
  false
else
  echo "Deployment input contains no example placeholders"
fi
```

### 7. Store the human-generated secrets

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
    verify-deployment.sh chatto-lightsail-*.sh
  shellcheck -x \
    chatto-operator-lib.sh provision-aws.sh install-host.sh \
    verify-deployment.sh chatto-lightsail-*.sh tests/*.sh
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
verification are pending. Confirm the SNS subscription. Add each CNAME printed
under `Publish these CNAME records` to the DNS zone for `jessedc.dev`; do not
alter the record names or targets. In the SES console for
`CHATTO_AWS_REGION`, request production access so Chatto can send to recipients
that are not separately verified SES identities.

After SNS is confirmed, Easy DKIM reports `Verified`, and SES production
access is approved, rerun without creating another backup access key:

```bash
./provision-aws.sh \
  --env chatto-deploy.env \
  --output chatto-provisioned.env \
  --smtp-credentials-output chatto-smtp-credentials.env
```

If the first run already created the SMTP credential, omit
`--smtp-credentials-output` on the rerun. The script never overwrites a
credential output, and AWS cannot recover either access-key secret. Store both
credential files in the password manager.

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
  chatto-smtp-credentials.env \
  chatto-tailscale-authkey.env \
  admin@LIGHTSAIL_IP:

ssh admin@LIGHTSAIL_IP
mkdir -p chatto-on-lightsail
tar -xzf chatto-host-installer.tgz -C chatto-on-lightsail
mv chatto-provisioned.env chatto-access-key.env \
  chatto-smtp-credentials.env \
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
ssh admin@LIGHTSAIL_IP \
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

Run the live backup and alert paths:

```bash
sudo ./verify-deployment.sh --run-backup --send-alert
```

Confirm the SNS test alert arrives. Log in as the owner, add an email address
from account settings, and confirm that the Chatto verification message
arrives from `noreply@jessedc.dev`. Complete the code challenge, then exercise
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
  credentials, SES SMTP credentials, the backup passphrase, and the recorded
  owner.
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
  `/etc/chatto/chatto.toml`, `/etc/chatto/chatto.env`,
  `/etc/chatto/smtp.env`, and the backup passphrase.
