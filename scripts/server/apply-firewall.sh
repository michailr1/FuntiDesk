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

echo "SSH_PORT=$ssh_port"
ufw allow "$ssh_port/tcp" comment 'SSH administration'
ufw allow 21115/tcp comment 'FuntiDesk hbbs NAT test'
ufw allow 21116/tcp comment 'FuntiDesk hbbs TCP'
ufw allow 21116/udp comment 'FuntiDesk hbbs UDP heartbeat'
ufw allow 21117/tcp comment 'FuntiDesk hbbr relay'

ufw default deny incoming
ufw default allow outgoing
ufw --force enable

ufw status verbose
