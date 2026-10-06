# FuntiDesk M1 — server live acceptance

Scope: live production evidence for R-01…R-04 after automated CI is green.

Target: `desk.funti.cc`.

## Preconditions

- repository is on the reviewed P0 branch/commit and working tree is clean;
- current production server public key is recorded before deployment;
- working SSH access is confirmed in a second session;
- old temporary relay-blocking firewall rules are absent;
- owner-controlled `age` recipient exists; only the public recipient is placed on the server;
- existing server identity is backed up before any destructive action.

## Deployment

Run the normal controlled deployment from `/opt/funtidesk/repo`.

After deployment:

```bash
sudo bash /opt/funtidesk/repo/scripts/server/acceptance-report.sh
```

Record the full output.

PASS requires:

- `SERVER_VERIFY_OK=true`;
- `DEPLOYED_COMMIT` equals the reviewed commit;
- `PUBLIC_KEY` equals the pre-deployment server identity;
- hbbs and hbbr are running from the same expected image;
- both services advertise the same persistent public key;
- only TCP/21115, TCP+UDP/21116 and TCP/21117 are published for FuntiDesk;
- SSH remains reachable on its real configured port.

## Encrypted backup / restore

1. Set only the owner-controlled public `AGE_RECIPIENT` on production.
2. Run `scripts/server/backup.sh`.
3. Copy the generated `.age` archive and `.sha256` sidecar off-host.
4. On a separate clean environment, provide the owner's age private identity via `AGE_IDENTITY_FILE`.
5. Run `restore-check.sh` with `EXPECTED_PUBLIC_KEY` set to the recorded server public key.
6. Require `RESTORE_CHECK_OK=true` and the same `PUBLIC_KEY`.
7. Do not leave the age private identity on the production server.

## External reachability

From a separate host verify:

- TCP/21115 reachable;
- TCP/21116 reachable;
- UDP/21116 reachable/usable for registration;
- TCP/21117 reachable;
- TCP/21118 and TCP/21119 not exposed.

Record source host, timestamp and commands/results.

## Evidence to copy into the review handoff

- acceptance date/time UTC;
- exact deployed commit;
- image digest / image ID;
- public server key;
- `verify.sh` result;
- encrypted backup filename + SHA256;
- clean restore-check result;
- confirmation of off-host backup;
- external port results.

Do not record server private keys, age private identities, passwords or access tokens.
