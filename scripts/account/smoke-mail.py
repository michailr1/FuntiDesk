#!/usr/bin/env python3
"""Проверка Postfix/DKIM и собственного API только во внутренней Docker-сети."""
import email
import email.policy
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import uuid

prefix = "funti-account-check-" + uuid.uuid4().hex[:10]
mail_image = os.environ["FUNTI_ACCOUNT_MAIL_IMAGE"]
api_image = os.environ["FUNTI_ACCOUNT_IMAGE"]
caddy_image = "caddy@sha256:748016f285ed8c43a9ce6e3aed6d92d3009d90ca41157950880f40beaf3ff62b"
network = prefix
mail = prefix + "-mail"
api = prefix + "-api"
witness = prefix + "-witness"
volumes = [prefix + suffix for suffix in ["-secrets", "-data", "-witness"]]
created_containers = []
created_volumes = []
network_created = False
queue_root = None


def docker(*arguments, data=None):
    result = subprocess.run(["docker", *arguments], input=data, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Docker test operation failed: " + arguments[0])
    output = result.stdout + result.stderr if arguments[0] == "logs" else result.stdout
    return output.strip()


http = r'''
use strict; use warnings; use IO::Socket::INET; use JSON::PP;
my $q=decode_json(do {local $/; <STDIN>});
my $s=IO::Socket::INET->new(PeerAddr=>$ARGV[0],PeerPort=>21800,Timeout=>10) or die "HTTP connect failed";
$s->autoflush(1);my $body=$q->{body}//'';
print $s "$q->{method} $q->{path} HTTP/1.1\r\nHost: desk.funti.cc\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: ".length($body)."\r\n";
while(my($k,$v)=each %{$q->{headers}}){print $s "$k: $v\r\n";}print $s "\r\n$body";
my $response=do {local $/;<$s>};my($head,$data)=split /\r\n\r\n/,$response,2;
my($status)=$head=~/^HTTP\/1\.1 (\d+)/;print encode_json({status=>0+$status,body=>$data});
'''

smtp = r'''
use strict; use warnings; use IO::Socket::INET;
my $s=IO::Socket::INET->new(PeerAddr=>$ARGV[0],PeerPort=>2525,Timeout=>10) or die "SMTP connect failed";
$s->autoflush(1);
sub response {
    my $line; do {$line=<$s>;die "SMTP closed" unless defined $line;} while $line=~/^\d{3}-/;
    return 0+substr($line,0,3);
}
my $status=response();
for my $command ("EHLO account-check\r\n", "MAIL FROM:<$ARGV[1]>\r\n", "RCPT TO:<person\@example.invalid>\r\n", "DATA\r\n") {
    last if $status>=400; print $s $command; $status=response();
}
if ($status==354) {
    print $s "From: no-reply\@funti.cc\r\nTo: person\@example.invalid\r\nSubject: isolated check\r\n\r\ncheck\r\n.\r\n";
    $status=response();
}
print $status;
'''

try:
    prepare_spec = importlib.util.spec_from_file_location("prepare_desk", Path(__file__).with_name("prepare-desk.py"))
    preparation = importlib.util.module_from_spec(prepare_spec)
    prepare_spec.loader.exec_module(preparation)
    queue_root = Path(tempfile.mkdtemp(prefix=prefix + "-queue-"))
    queue_path = queue_root / "queue"
    previous_umask = os.umask(0o077)
    try:
        preparation.create_mail_queue(queue_path, os.getuid(), os.getgid())
    finally:
        os.umask(previous_umask)
    assert queue_path.stat().st_mode & 0o777 == 0o755, "queue inherited restrictive umask"
    assert not list(queue_path.iterdir()), "queue fixture must start empty"
    # The test runner need not be root; the disposable mount matches production ownership.
    docker("run", "--rm", "--network", "none", "--entrypoint", "chown",
           "--mount", "type=bind,source=" + str(queue_path) + ",target=/queue", mail_image, "0:0", "/queue")
    docker("network", "create", "--internal", "--subnet", os.environ.get("FUNTI_ACCOUNT_TEST_SUBNET", "172.31.249.0/29"), network)
    network_created = True
    config = json.loads(docker("network", "inspect", network))[0]
    subnet = ipaddress.ip_network(config["IPAM"]["Config"][0]["Subnet"])
    mail_ip, api_ip, witness_ip = [str(subnet.network_address + i) for i in [2, 3, 4]]
    for volume in volumes:
        docker("volume", "create", volume)
        created_volumes.append(volume)
    docker("run", "--rm", "--network", "none", "--entrypoint", "sh",
           "-v", volumes[0] + ":/secrets", "-v", volumes[1] + ":/data", "-v", volumes[2] + ":/witness", mail_image, "-c",
           "umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /secrets/dkim.private 2>/dev/null; "
           "openssl rand -hex 32 > /secrets/account.key; openssl rand -hex 32 > /secrets/witness.key; "
           "chown 10001:10001 /secrets/account.key /secrets/witness.key /data /witness; "
           "chmod 0400 /secrets/account.key /secrets/witness.key; chmod 0700 /data /witness")
    witness_options = ["--network", network, "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
                       "-e", "FUNTI_ACCOUNT_WITNESS_KEY_FILE=/secrets/witness.key",
                       "-e", "FUNTI_ACCOUNT_WITNESS_NAMESPACE=" + "77" * 32,
                       "-e", "FUNTI_WITNESS_DIRECTORY=/data/witness", "-e", "FUNTI_WITNESS_LISTEN=0.0.0.0:21802",
                       "-v", volumes[0] + ":/secrets:ro", "-v", volumes[2] + ":/data"]
    docker("run", "--rm", *witness_options, api_image, "witness-init")
    created_containers.append(witness)
    docker("run", "-d", "--name", witness, "--ip", witness_ip, "--network-alias", "funtidesk-account-witness-relay", *witness_options, api_image, "witness")
    account_options = ["--network", network, "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
                       "-e", "FUNTI_ACCOUNT_LISTEN=0.0.0.0:21800", "-e", "FUNTI_ACCOUNT_DATABASE=/data/account.sqlite3",
                       "-e", "FUNTI_ACCOUNT_KEY_FILE=/secrets/account.key", "-e", "FUNTI_ACCOUNT_SMTP_HOST=" + mail_ip,
                       "-e", "FUNTI_ACCOUNT_SMTP_PORT=2525", "-e", "FUNTI_ACCOUNT_WITNESS_KEY_FILE=/secrets/witness.key",
                       "-e", "FUNTI_ACCOUNT_WITNESS_NAMESPACE=" + "77" * 32,
                       "-e", "FUNTI_ACCOUNT_WITNESS_URL=http://funtidesk-account-witness-relay:21802/v1/witness",
                       "-v", volumes[0] + ":/secrets:ro", "-v", volumes[1] + ":/data"]
    for _ in range(60):
        try:
            docker("run", "--rm", *account_options, api_image, "initialize")
            break
        except RuntimeError:
            time.sleep(0.25)
    else:
        raise RuntimeError("Independent state initialization failed")
    options = ["--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true"]
    for capability in ["CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID", "KILL"]:
        options += ["--cap-add", capability]
    for path in ["/run", "/tmp", "/etc/opendkim", "/etc/postfix", "/var/lib/postfix"]:
        options += ["--tmpfs", path]
    created_containers.append(mail)
    docker("run", "-d", "--name", mail, "--network", network, "--ip", mail_ip,
           *options, "-e", "FUNTI_MAIL_BIND_IP=" + mail_ip, "-e", "FUNTI_MAIL_SUBNET=" + str(subnet),
           "-v", volumes[0] + ":/secrets:ro",
           "--mount", "type=bind,source=" + str(queue_path) + ",target=/var/spool/postfix", mail_image)
    for _ in range(60):
        if subprocess.run(["docker", "exec", mail, "postfix", "status"], capture_output=True).returncode == 0:
            break
        time.sleep(0.25)
    else:
        raise RuntimeError("SMTP startup failed")
    assert docker("exec", mail, "stat", "-c", "%a %u:%g", "/var/spool/postfix") == "755 0:0"
    assert docker("exec", mail, "stat", "-c", "%a", "/var/spool/postfix/private") == "700"
    docker("exec", mail, "sh", "-c", "postconf -e defer_transports=smtp; postfix reload")
    created_containers.append(api)
    docker("run", "-d", "--name", api, "--ip", api_ip, *account_options, api_image)

    def request(path, body=None, extra=None):
        headers = {"X-Funti-Client": "native", **(extra or {})}
        payload = {"method": "GET" if body is None else "POST", "path": path, "headers": headers,
                   "body": "" if body is None else json.dumps(body)}
        raw = docker("exec", "-i", mail, "perl", "-e", http, api_ip, data=json.dumps(payload))
        return json.loads(raw)

    for _ in range(60):
        try:
            assert request("/health")["body"] == "ok"
            break
        except (RuntimeError, AssertionError):
            time.sleep(0.25)
    else:
        raise RuntimeError("API startup failed")
    # Exercise the activation client's actual shell/nc against a running API.
    spec = importlib.util.spec_from_file_location("activate_desk", Path(__file__).with_name("activate-desk.py"))
    activation = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(activation)
    activation.private_request(caddy_image, "/health", 200, b"ok", network=network, host=api_ip)
    activation.private_request(caddy_image, "/api/account/v1/session", 401, b"authentication_required",
                               network=network, host=api_ip)
    base = "/api/account/v1"
    boot = request(base + "/auth/bootstrap")
    context = json.loads(boot["body"])["login_context"]
    begin = request(base + "/auth/request", {"email": "person@example.invalid"}, {"X-Funti-Login": context})
    assert begin["status"] == 202, "mail request was rejected"
    challenge = json.loads(begin["body"])["challenge_id"]
    message = None
    signature = ""
    for _ in range(60):
        rows = [json.loads(line) for line in docker("exec", mail, "postqueue", "-j").splitlines()]
        for row in rows:
            # Preserve all MIME headers; their order is not fixed by the mail library.
            raw = docker("exec", mail, "postcat", "-bh", "-q", row["queue_id"])
            if raw.startswith("*** "):
                raw = raw.partition("\n")[2]
            raw = raw.split("\n*** ", 1)[0]
            if "person@example.invalid" in raw and "DKIM-Signature:" in raw:
                signature_match = re.search(r"(?m)^DKIM-Signature:([^\n]*(?:\n[ \t][^\n]*)*)", raw)
                if signature_match:
                    signature = re.sub(r"\s+", "", signature_match.group(1))
                message = email.message_from_string(raw, policy=email.policy.default)
        if message:
            break
        time.sleep(0.25)
    assert message is not None, "signed API mail was not queued"
    assert "d=funti.cc" in signature and "s=funtidesk202610" in signature, "wrong DKIM identity"
    assert "Код входа:" in message.get_content(), "mail does not declare readable UTF-8 text"
    code = re.search(r"\b\d{6}\b", message.get_content()).group()
    verified = request(base + "/auth/verify", {"challenge_id": challenge, "code": code}, {"X-Funti-Login": context})
    assert verified["status"] == 200, "queued code does not verify"
    token = json.loads(verified["body"])["token"]
    session = request(base + "/session", extra={"Authorization": "Bearer " + token})
    assert session["status"] == 200, "native session does not work"
    docker("stop", api)
    restored_options = account_options + ["-e", "FUNTI_ACCOUNT_DATABASE=/data/restored.sqlite3"]
    receipt = docker("run", "--rm", *restored_options, api_image, "restore")
    assert "ACCOUNT_RECOVERED" in receipt and "event_highwater=1" in receipt
    docker("rm", api)
    docker("run", "-d", "--name", api, "--ip", api_ip, *restored_options, api_image)
    for _ in range(60):
        try:
            session = request(base + "/session", extra={"Authorization": "Bearer " + token})
            assert session["status"] == 401, "old session survived actual CLI restore"
            break
        except RuntimeError:
            time.sleep(0.25)
    else:
        raise RuntimeError("Restored API startup failed")
    refused = int(docker("exec", mail, "perl", "-e", smtp, mail_ip, "other@funti.cc"))
    assert 500 <= refused < 600, "unapproved sender was accepted"
    docker("exec", mail, "perl", "-e",
           "open my $f,'<','/run/opendkim/dkim.pid' or die; my $pid=<$f>; chomp $pid; kill 'TERM',$pid or die;")
    refused = int(docker("exec", mail, "perl", "-e", smtp, mail_ip, "no-reply@funti.cc"))
    assert 400 <= refused < 500, "mail was accepted without DKIM"
    for container in created_containers:
        logs = docker("logs", container)
        assert all(value not in logs for value in ["person@example.invalid", code, token, challenge, context]), "secret leaked to logs"
    assert docker("exec", mail, "postconf", "-h", "maillog_file") == "/dev/null"
    assert docker("exec", mail, "postconf", "-h", "inet_interfaces") == mail_ip
    print("ACCOUNT_SMTP_DKIM_SMOKE_OK: private network, real queued code, independent encrypted state, CLI restore invalidates session, sender/DKIM refusal, log privacy")
finally:
    for container in reversed(created_containers):
        subprocess.run(["docker", "rm", "-f", container], capture_output=True)
    for volume in created_volumes:
        subprocess.run(["docker", "volume", "rm", volume], capture_output=True)
    if network_created:
        subprocess.run(["docker", "network", "rm", network], capture_output=True)
    if queue_root is not None:
        docker("run", "--rm", "--network", "none", "--entrypoint", "sh",
               "--mount", "type=bind,source=" + str(queue_root) + ",target=/fixture", mail_image,
               "-c", "find /fixture -mindepth 1 -delete")
        queue_root.rmdir()
