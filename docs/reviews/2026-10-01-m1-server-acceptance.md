# FuntiDesk M1 — production server acceptance

Scope: live acceptance for R-01…R-04 on `desk.funti.cc` after PR #7 code/CI is green.

## Preconditions

- Preserve a working SSH session before firewall changes.
- Record current deployed server public key before deployment.
- Do not rotate `/opt/funtidesk/data/id_ed25519`.
- Do not modify unrelated Docker/Caddy/Remnawave services or their existing firewall rules/listeners.
- Repository on server must be clean; `deploy.sh` intentionally refuses dirty/untracked trees.
- Use the exact reviewed PR #7 head unless a newer reviewed commit is explicitly recorded.

## 1. Pre-deploy snapshot

Record, without exposing secrets:

```bash
cd /opt/funtidesk/repo
git status --short
git rev-parse HEAD
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
sudo ss -lntup
sudo cat /opt/funtidesk/data/id_ed25519.pub
```

Copy the public key into the acceptance report. Never output the private key.

## 2. Encrypted backup

Install `age` if not already present. The owner age recipient must be supplied out-of-band as `AGE_RECIPIENT`; the private age identity must not be stored in Git.

```bash
sudo -E AGE_RECIPIENT="$AGE_RECIPIENT"   bash /opt/funtidesk/repo/scripts/server/backup.sh
```

Record:
- encrypted archive path;
- SHA256 sidecar path;
- encrypted artifact SHA256;
- confirmation that there is no persistent plaintext `.tar.gz` backup.

Copy the encrypted archive and sidecar off-host using the owner's approved storage/channel.

## 3. Deploy reviewed commit

```bash
cd /opt/funtidesk/repo
git fetch --all --prune
git checkout --detach <REVIEWED_PR7_SHA>
git status --short
sudo bash scripts/server/deploy.sh
```

PASS requires:
- clean-tree check passes;
- `SERVER_VERIFY_OK=true`;
- `/opt/funtidesk/DEPLOYED_COMMIT` exactly matches the reviewed commit;
- `PUBLIC_KEY` equals the pre-deploy server public key.

## 4. R-01 relay key enforcement

```bash
sudo docker inspect funtidesk-hbbs --format '{{json .Config.Cmd}}'
sudo docker inspect funtidesk-hbbr --format '{{json .Config.Cmd}}'
sudo docker logs funtidesk-hbbs 2>&1 | tail -n 80
sudo docker logs funtidesk-hbbr 2>&1 | tail -n 80
```

PASS:
- hbbs command includes `-k _`;
- hbbr command includes `-k _`;
- both report the same persistent public key;
- public key equals `/opt/funtidesk/data/id_ed25519.pub`.

## 5. R-04 listener/published-port acceptance

Run the repository verification twice:

```bash
sudo bash /opt/funtidesk/repo/scripts/server/verify.sh
sudo bash /opt/funtidesk/repo/scripts/server/verify.sh
```

Then record:

```bash
sudo docker port funtidesk-hbbs
sudo docker port funtidesk-hbbr
sudo ss -lntup
sudo stat -c '%a %n' /opt/funtidesk/data/id_ed25519 /opt/funtidesk/data/id_ed25519.pub
```

PASS:
- hbbs publishes only 21115/tcp, 21116/tcp, 21116/udp;
- hbbr publishes only 21117/tcp;
- 21118/21119 are not exposed;
- private key mode 600, public key mode 644;
- running verify twice does not mutate key files.

## 6. Firewall

Before applying, record effective SSH port:

```bash
sudo sshd -T | awk '$1=="port"{print $2}'
```

First record existing firewall state and unrelated listeners:

```bash
sudo ufw status verbose
sudo ss -lntup
```

If UFW is already active, keep the existing SSH session open and run:

```bash
sudo bash /opt/funtidesk/repo/scripts/server/apply-firewall.sh
sudo ufw status verbose
```

If UFW is inactive, **do not enable it automatically on this shared host**. Inventory every required non-FuntiDesk service/rule first; use `FUNTIDESK_ENABLE_UFW=1` only after explicit owner approval of that inventory.

Open a **new** SSH session before closing the old one.

PASS: SSH still works on the real configured port; FuntiDesk ports remain reachable; unrelated pre-existing web/TLS/VPN/control services remain unchanged. Docker published ports traverse DNAT/FORWARD, so UFW INPUT alone is not the acceptance control.

## 7. External port check

From a host outside the VPS network, check:

- TCP 21115 open;
- TCP 21116 open;
- UDP 21116 observable through actual client registration/NAT test;
- TCP 21117 open;
- TCP 21118 and 21119 closed.

Record source host/network and timestamp.

## 8. Restore-check

On an isolated clean environment, not on the live production data directory:

```bash
AGE_IDENTITY_FILE=/secure/path/owner.agekey EXPECTED_PUBLIC_KEY='<recorded production public key>' bash scripts/server/restore-check.sh /path/to/funtidesk-server-*.tar.gz.age
```

PASS requires `RESTORE_CHECK_OK=true` and the same `PUBLIC_KEY`.

For full M1 acceptance, perform an actual isolated restore from the encrypted backup and start hbbs/hbbr against the restored data. Both must report the same original public key.

## 9. Evidence to return

```text
REVIEWED_COMMIT=
DEPLOYED_COMMIT=
PUBLIC_KEY=
HBBS_KEY_CHECK=true/false
HBBR_KEY_CHECK=true/false
VERIFY_TWICE_PASS=
PUBLISHED_PORTS_PASS=
SSH_PORT=
FIREWALL_PASS=
EXTERNAL_PORT_CHECK_PASS=
BACKUP_ENCRYPTED=
BACKUP_SHA256=
OFFHOST_COPY_CONFIRMED=
RESTORE_CHECK_PASS=
RESTORED_PUBLIC_KEY=
ERRORS=
```

Do not include passwords, private keys, access tokens, or the private age identity.
