#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

command -v ufw >/dev/null 2>&1 || { echo "ERROR: ufw is not installed" >&2; exit 1; }

ssh_port="${SSH_PORT:-}"
if [[ -z "$ssh_port" ]]; then
  command -v sshd >/dev/null 2>&1 || { echo "ERROR: sshd not found and SSH_PORT is unset" >&2; exit 1; }
  ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
fi

if [[ ! "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then
  echo "ERROR: unable to determine a valid SSH port; set SSH_PORT explicitly" >&2
  exit 1
fi

ufw_status="$(ufw status | head -n1 || true)"
if [[ "$ufw_status" != "Status: active" && "${FUNTIDESK_ENABLE_UFW:-0}" != "1" ]]; then
  echo "ERROR: UFW is not active. This host may run unrelated services; refusing to enable/change global firewall policy automatically." >&2
  echo "Inspect existing listeners/rules first, then re-run with FUNTIDESK_ENABLE_UFW=1 only if enabling UFW is explicitly approved." >&2
  exit 1
fi

echo "SSH_PORT=$ssh_port"

# FUNTIDESK: additive rules only. This script must not remove unrelated host rules
# or change global default policies on a shared production host.
ufw allow "$ssh_port/tcp" comment 'SSH administration'
ufw allow 21115/tcp comment 'FuntiDesk hbbs NAT test'
ufw allow 21116/tcp comment 'FuntiDesk hbbs TCP'
ufw allow 21116/udp comment 'FuntiDesk hbbs UDP heartbeat'
ufw allow 21117/tcp comment 'FuntiDesk hbbr relay'

if [[ "$ufw_status" != "Status: active" ]]; then
  ufw --force enable
fi

ufw status verbose
