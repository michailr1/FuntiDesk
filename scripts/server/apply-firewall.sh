#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

command -v ufw >/dev/null 2>&1 || { echo "ERROR: ufw is not installed" >&2; exit 1; }

ufw allow 22/tcp comment 'SSH administration'
ufw allow 21115/tcp comment 'FuntiDesk hbbs NAT test'
ufw allow 21116/tcp comment 'FuntiDesk hbbs TCP'
ufw allow 21116/udp comment 'FuntiDesk hbbs UDP heartbeat'
ufw allow 21117/tcp comment 'FuntiDesk hbbr relay'

ufw default deny incoming
ufw default allow outgoing
ufw --force enable

ufw status verbose
