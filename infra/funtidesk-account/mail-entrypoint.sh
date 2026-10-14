#!/bin/sh
set -eu
umask 077

: "${FUNTI_MAIL_BIND_IP:?private SMTP address required}"
: "${FUNTI_MAIL_SUBNET:?private SMTP subnet required}"
test -s /secrets/dkim.private || { echo 'DKIM key is missing' >&2; exit 1; }

mkdir -p /run/opendkim /etc/opendkim /etc/postfix /var/lib/postfix
chown postfix:postfix /var/lib/postfix
cp -a /usr/share/funtidesk-mail/postfix/. /etc/postfix/
cp /secrets/dkim.private /run/opendkim/private.key
chown -R opendkim:postfix /run/opendkim
chmod 0750 /run/opendkim
chmod 0600 /run/opendkim/private.key

cat > /etc/opendkim/KeyTable <<'EOF'
funtidesk202610._domainkey.funti.cc funti.cc:funtidesk202610:/run/opendkim/private.key
EOF
cat > /etc/opendkim/SigningTable <<'EOF'
no-reply@funti.cc funtidesk202610._domainkey.funti.cc
EOF
printf '127.0.0.1\n%s\n' "$FUNTI_MAIL_SUBNET" > /etc/opendkim/TrustedHosts
cat > /etc/opendkim/opendkim.conf <<'EOF'
Syslog no
LogWhy no
Mode s
Canonicalization relaxed/simple
SignatureAlgorithm rsa-sha256
UserID opendkim
UMask 007
Socket local:/run/opendkim/dkim.sock
PidFile /run/opendkim/dkim.pid
KeyTable /etc/opendkim/KeyTable
SigningTable /etc/opendkim/SigningTable
InternalHosts /etc/opendkim/TrustedHosts
ExternalIgnoreList /etc/opendkim/TrustedHosts
OversignHeaders From
EOF
chown -R opendkim:opendkim /etc/opendkim

# Only the private interface listens; outgoing SMTP has no public listener.
awk ' /^[^# \t]/ && NF >= 8 { $5="n"; if ($1=="smtp" && $2=="inet") $1="2525" } {print}' \
  /usr/share/funtidesk-mail/postfix/master.cf > /etc/postfix/master.cf
cat > /etc/postfix/allowed_from <<'EOF'
/^no-reply@funti[.]cc$/ OK
/./ REJECT
EOF
postconf -e \
  'myhostname=core.funti.cc' 'mydomain=funti.cc' 'mydestination=' \
  'inet_protocols=ipv4' "inet_interfaces=$FUNTI_MAIL_BIND_IP" \
  "mynetworks=$FUNTI_MAIL_SUBNET" \
  'smtpd_relay_restrictions=permit_mynetworks,reject_unauth_destination' \
  'smtpd_sender_restrictions=check_sender_access regexp:/etc/postfix/allowed_from' \
  'smtpd_milters=unix:/run/opendkim/dkim.sock' \
  'non_smtpd_milters=unix:/run/opendkim/dkim.sock' 'milter_default_action=tempfail' \
  'milter_protocol=6' 'maillog_file=/dev/null' 'maillog_file_prefixes=/dev/null' 'notify_classes=' \
  'smtp_tls_security_level=verify' 'smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt' \
  'smtp_helo_name=core.funti.cc' 'maximal_queue_lifetime=5m' 'bounce_queue_lifetime=0' \
  'message_size_limit=65536' 'default_process_limit=20' \
  'queue_directory=/var/spool/postfix' 'data_directory=/var/lib/postfix'

opendkim -f -x /etc/opendkim/opendkim.conf &
dkim_pid=$!
tries=0
while [ ! -S /run/opendkim/dkim.sock ]; do
  kill -0 "$dkim_pid" || { echo 'DKIM failed to start' >&2; exit 1; }
  tries=$((tries + 1))
  [ "$tries" -le 50 ] || { echo 'DKIM socket unavailable' >&2; exit 1; }
  sleep 0.2
done
postfix check
exec postfix start-fg
