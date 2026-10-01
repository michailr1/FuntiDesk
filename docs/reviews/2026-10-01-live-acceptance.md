# FuntiDesk — live acceptance plan after external review

Date: 2026-10-01.

This checklist records the **remaining live evidence** after automated CI. It must not be marked PASS from source inspection alone.

## A. M1 server acceptance (R-01…R-04)

Target: production `desk.funti.cc`.

Preconditions:

- production repository is on the reviewed P0 branch/commit and clean;
- existing server identity is backed up before deployment;
- current public key is recorded;
- SSH access has been tested in a second session;
- relay TCP/21117 is not left blocked by an old test firewall rule;
- an owner-controlled `age` recipient exists. Only the public recipient belongs on the server.

Run the controlled deployment, then:

```bash
sudo bash /opt/funtidesk/repo/scripts/server/acceptance-report.sh
```

Required evidence:

- `SERVER_VERIFY_OK=true`;
- `DEPLOYED_COMMIT` equals the reviewed deployment commit;
- `PUBLIC_KEY` equals the previously approved server identity;
- hbbs and hbbr use the same image ID and same persistent public key;
- only TCP/21115, TCP+UDP/21116 and TCP/21117 are published for FuntiDesk;
- SSH remains reachable on its actual configured port.

Backup evidence:

1. run `backup.sh` with the owner-controlled `AGE_RECIPIENT`;
2. copy `.age` and `.sha256` off-host;
3. on a separate clean environment, use the owner's age identity to run `restore-check.sh`;
4. require `RESTORE_CHECK_OK=true` and the same `PUBLIC_KEY`;
5. never leave the age private identity on the production server.

External reachability must be checked from a separate host. Record TCP/21115, TCP/21116, UDP/21116 and TCP/21117; 21118/21119 must remain closed.

## B. Windows M2 security acceptance (R-10…R-16)

Use the exact artifact produced by the reviewed security-branch clean Windows build and preserve its SHA256 manifest.

Use a clean Windows VM/profile so legacy RustDesk settings cannot affect the result.

### B1. Infrastructure pinning / renamed executable

1. Rename the executable to a filename containing a fake host/key payload recognizable by the old upstream parser.
2. Start FuntiDesk.
3. Confirm logs and sockets still use only `desk.funti.cc`.
4. Confirm the fake host/key was not persisted to user config.
5. Edit mutable config to contain a foreign rendezvous/key; restart.
6. Confirm FuntiDesk still uses only its build-time endpoint/key.

PASS: runtime and persisted config cannot redirect rendezvous/relay/API/trust anchor.

### B2. custom.txt negative test

Place a syntactically valid upstream-style `custom.txt` next to the executable and start FuntiDesk.

PASS: app name, endpoint, server key and security policy do not change; the file has no trust effect.

### B3. Fail-closed handshake

Run negative cases separately:

- client configured/modified to present a wrong rendezvous trust key;
- fake hbbs identity;
- missing/invalid signed peer key;
- empty/invalid peer `PublicKey`.

PASS: every case rejects the session. No remote-control session exists and no plaintext fallback appears in logs.

### B4. Safe defaults

On a clean profile verify:

- direct-server: disabled/locked;
- LAN discovery: disabled/locked;
- remote config modification: disabled/locked;
- insecure TLS fallback: disabled/locked;
- permanent unattended password: absent;
- temporary password: enabled;
- approve mode / verification method match `docs/SECURITY.md`.

### B5. External network audit

Capture DNS + TCP + UDP for:

1. application startup;
2. successful connection;
3. `desk.funti.cc` unavailable;
4. wrong-key failure.

Compare with `docs/NETWORK_ALLOWLIST.md`.

PASS: no connection to an endpoint outside the committed allowlist. Static documentation URLs are not evidence of runtime traffic.

### B6. Windows↔Windows functional regression

After security negative tests PASS:

- relay fallback works through `desk.funti.cc:21117`;
- direct P2P works where NAT permits;
- control, clipboard and file transfer still work;
- Ethernet ↔ mobile-hotspot network-change behavior from MIK-16 is rechecked on the security build.

## Release gate

Do **not** distribute the Windows build to family/friends until sections A and B have recorded evidence and R-10…R-16 are closed in Linear.
