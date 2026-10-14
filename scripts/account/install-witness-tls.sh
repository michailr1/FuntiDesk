#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ $# -eq 2 ]] || { echo 'Usage: install-witness-tls.sh SOURCE_CERTIFICATE SOURCE_KEY' >&2; exit 1; }
FUNTI_TLS_REPO=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
[[ -z $(git -C "$FUNTI_TLS_REPO" status --porcelain=v1 --untracked-files=all) ]] || {
  echo 'ERROR: installation requires committed, clean repository' >&2; exit 1;
}
for argument in "$1" "$2"; do
  [[ $argument =~ ^/[a-zA-Z0-9._/-]+$ && -f $argument ]] || {
    echo 'ERROR: expected existing absolute Caddy certificate/key path' >&2; exit 1;
  }
done
for command in python3 openssl docker install systemctl; do command -v "$command" >/dev/null; done

python3 - <<'PY'
from pathlib import Path
marker = '# Managed by FuntiDesk scripts/account/install-witness-tls.sh'
for name in ['/usr/local/libexec/funtidesk-account-sync-witness-tls.py',
             '/etc/funtidesk-account-witness-tls.env',
             '/etc/systemd/system/funtidesk-account-witness-tls.service',
             '/etc/systemd/system/funtidesk-account-witness-tls.timer']:
    path = Path(name)
    if path.is_symlink():
        raise SystemExit('ERROR: managed installation path is a symlink')
    if path.exists():
        with path.open() as stream:
            if marker not in [stream.readline().strip(), stream.readline().strip()]:
                raise SystemExit('ERROR: refusing to replace unmanaged TLS configuration')
for name in ['/opt/funtidesk-account-witness', '/opt/funtidesk-account-witness/secrets',
             '/opt/funtidesk-account-witness/secrets/tls']:
    if Path(name).is_symlink():
        raise SystemExit('ERROR: witness TLS installation path is a symlink')
PY
install -d -m 0700 /opt/funtidesk-account-witness/secrets/tls
install -d -m 0755 /usr/local/libexec
install -m 0755 "$FUNTI_TLS_REPO/scripts/account/sync-witness-tls.py" /usr/local/libexec/funtidesk-account-sync-witness-tls.py
python3 /usr/local/libexec/funtidesk-account-sync-witness-tls.py --certificate "$1" --key "$2" --directory /opt/funtidesk-account-witness/secrets/tls

FUNTI_TLS_ENV=$(mktemp)
trap 'rm -f "$FUNTI_TLS_ENV"' EXIT
printf '# Managed by FuntiDesk scripts/account/install-witness-tls.sh\nFUNTI_WITNESS_TLS_SOURCE_CERTIFICATE=%s\nFUNTI_WITNESS_TLS_SOURCE_KEY=%s\n' "$1" "$2" > "$FUNTI_TLS_ENV"
install -m 0600 "$FUNTI_TLS_ENV" /etc/funtidesk-account-witness-tls.env
install -m 0644 "$FUNTI_TLS_REPO/infra/funtidesk-account/funtidesk-account-witness-tls.service" /etc/systemd/system/funtidesk-account-witness-tls.service
install -m 0644 "$FUNTI_TLS_REPO/infra/funtidesk-account/funtidesk-account-witness-tls.timer" /etc/systemd/system/funtidesk-account-witness-tls.timer
systemctl daemon-reload
systemctl enable --now funtidesk-account-witness-tls.timer
systemctl start funtidesk-account-witness-tls.service
git -C "$FUNTI_TLS_REPO" rev-parse HEAD
systemctl is-active funtidesk-account-witness-tls.timer
systemctl show funtidesk-account-witness-tls.service -p Result -p ExecMainStatus
