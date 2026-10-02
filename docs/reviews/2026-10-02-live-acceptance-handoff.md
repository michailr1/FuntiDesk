# FuntiDesk — live acceptance handoff

Purpose: finish the external-review acceptance after automated CI is green. This document contains no secrets.

## Preconditions

- Security branch: `michailr/m2-security-review-fixes`.
- Use the GitHub Actions Windows runtime artifact produced by `.github/workflows/r21-windows-clean-build.yml` for the exact tested source SHA.
- Both Windows endpoints use the same artifact unless a negative scenario explicitly says otherwise.
- Production server identity must remain unchanged.
- Do not delete existing profiles; use disposable profiles/copies for destructive negative tests.
- Do not record passwords, private server keys, access tokens or age private identities in evidence.

## Windows controller

For every scenario run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/security-acceptance.ps1 -ExePath <runtime-exe>
```

Preserve the generated report and the matching client log excerpt.

Execute A1–A8 from `docs/reviews/2026-10-01-m2-windows-acceptance.md`.

Required final markers:

```text
A1_RENAMED_EXE=PASS
A2_HOSTILE_CONFIG=PASS
A3_CUSTOM_TXT=PASS
A4_WRONG_SERVER_KEY=PASS
A5_INVALID_PUBLIC_KEY=PASS
A6_SAFE_DEFAULTS=PASS
A7_NETWORK_ALLOWLIST=PASS
A8_WINDOWS_E2E=PASS
```

For A8 preserve separate evidence for:
- direct P2P;
- relay fallback;
- Ethernet → mobile hotspot without application restart.

## Windows remote endpoint

Use the same runtime SHA and keep VPN off unless a scenario explicitly requires it.

Preserve:
- exact device ID;
- runtime SHA256;
- client log excerpt matching controller timestamps;
- transport socket evidence for direct and relay cases.

Do not reset device identity unless explicitly approved.

## Production server rollout (PR #7)

Before deployment:
- preserve current server identity and backup;
- confirm a second SSH session works;
- confirm no unrelated Caddy/Remnawave services are touched.

Deploy only the P0 server branch after its current CI is green.

After deployment run:

```bash
sudo bash /opt/funtidesk/repo/scripts/server/live-acceptance.sh
```

Required evidence:
- exact `DEPLOYED_COMMIT`;
- current `PUBLIC_KEY`;
- hbbs/hbbr commands include `-k _`;
- published ports are only 21115/tcp, 21116/tcp+udp, 21117/tcp;
- `SERVER_VERIFY_OK=true`;
- existing public server key is unchanged.

## Encrypted backup / restore (R-03)

Production backup requires the owner's age **public recipient** through `AGE_RECIPIENT`. The age private identity must stay off the server/repository except when explicitly used for restore verification through a secure channel.

Acceptance:
- encrypted `.tar.gz.age` artifact;
- SHA256 sidecar;
- `restore-check.sh` returns `RESTORE_CHECK_OK=true`;
- restored server public key equals the recorded production `PUBLIC_KEY`.

## Completion

Only after all Windows A1–A8 and server R-01…R-04 live evidence are PASS:
- update the external-review developer-response table with final evidence;
- mark MIK-26…MIK-29 and MIK-33…MIK-39 Done;
- merge PR #7, then PR #8;
- do not distribute the M2 build before this point.
