#!/usr/bin/env python3
"""Настоящий HTTPS Caddy → witness во временной внутренней Docker-сети."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

image = os.environ["FUNTI_ACCOUNT_IMAGE"]
caddy_image = "caddy@sha256:748016f285ed8c43a9ce6e3aed6d92d3009d90ca41157950880f40beaf3ff62b"
root = Path(__file__).resolve().parents[2]
prefix = "funti-witness-tls-check-" + uuid.uuid4().hex[:10]
containers = []
network_created = False
ingress_created = False


def docker(*arguments):
    result = subprocess.run(["docker", *arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError("Witness TLS Docker operation failed: " + arguments[0])
    return result.stdout.strip()


def compact(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def tag(key, purpose, value):
    mac = hmac.new(key, digestmod=hashlib.sha256)
    for item in [purpose, value]:
        data = item.encode()
        mac.update(len(data).to_bytes(8, "big"))
        mac.update(data)
    return mac.hexdigest()


with tempfile.TemporaryDirectory(prefix=prefix) as temporary:
    base = Path(temporary)
    key = os.urandom(32)
    namespace = os.urandom(32).hex()
    key_file = base / "witness.key"
    key_file.write_text(key.hex())
    key_file.chmod(0o600)
    data = base / "data"
    data.mkdir(mode=0o700)
    tls = base / "tls"
    tls.mkdir(mode=0o700)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=de.funti.cc", "-addext", "subjectAltName=DNS:de.funti.cc",
                    "-keyout", str(tls / "privkey.pem"), "-out", str(tls / "fullchain.pem")],
                   check=True, capture_output=True)
    options = ["--network", prefix, "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
               "--user", f"{os.getuid()}:{os.getgid()}", "-e", "FUNTI_ACCOUNT_WITNESS_KEY_FILE=/secrets/witness.key",
               "-e", "FUNTI_ACCOUNT_WITNESS_NAMESPACE=" + namespace, "-e", "FUNTI_WITNESS_DIRECTORY=/data/witness",
               "-e", "FUNTI_WITNESS_LISTEN=0.0.0.0:21802", "-v", str(key_file) + ":/secrets/witness.key:ro",
               "-v", str(data) + ":/data"]
    try:
        docker("network", "create", "--internal", prefix)
        network_created = True
        docker("network", "create", prefix + "-ingress")
        ingress_created = True
        docker("run", "--rm", *options, image, "witness-init")
        witness = prefix + "-witness"
        containers.append(witness)
        docker("run", "-d", "--name", witness, "--network-alias", "funtidesk-account-witness", *options, image, "witness")
        caddy = prefix + "-caddy"
        containers.append(caddy)
        docker("run", "-d", "--name", caddy, "--network", prefix + "-ingress", "--read-only", "--cap-drop", "ALL",
               "--cap-add", "NET_BIND_SERVICE",
               "-e", "NO_PROXY=funtidesk-account-witness,127.0.0.1,localhost",
               "-e", "no_proxy=funtidesk-account-witness,127.0.0.1,localhost",
               "--user", f"{os.getuid()}:{os.getgid()}", "--security-opt", "no-new-privileges:true",
               "--tmpfs", f"/config:mode=0700,uid={os.getuid()},gid={os.getgid()}",
               "--tmpfs", f"/data:mode=0700,uid={os.getuid()},gid={os.getgid()}",
               "-p", "127.0.0.1::8446", "-v", str(tls) + ":/certs:ro",
               "-v", str(root / "infra/funtidesk-account/Caddyfile.witness.proposed") + ":/etc/caddy/Caddyfile:ro", caddy_image)
        docker("network", "connect", prefix, caddy)
        for _ in range(20):
            inspected=json.loads(docker("inspect", caddy))[0]
            ports=inspected["NetworkSettings"]["Ports"]
            if ports.get("8446/tcp") or not inspected["State"]["Running"]:break
            time.sleep(0.1)
        if not ports.get("8446/tcp"):
            raise RuntimeError("Witness TLS port unavailable; status=" + str(inspected["State"]["Status"]) + "; error=" + str(inspected["State"]["Error"]) + "; " + docker("logs", caddy)[-1500:])
        port = int(ports["8446/tcp"][0]["HostPort"])
        def request(path, payload):
            body=compact(payload).encode()
            raw=(f"POST {path} HTTP/1.1\r\nHost: de.funti.cc:8446\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n").encode()+body
            client=prefix+"-client"
            try:
                result=subprocess.run(["docker","run","--rm","--name",client,"-i","--network","host","--entrypoint","openssl",
                "-v",str(tls / "fullchain.pem")+":/CA.pem:ro",os.environ["FUNTI_ACCOUNT_MAIL_IMAGE"],"s_client",
                "-quiet","-verify_return_error","-verify_hostname","de.funti.cc","-CAfile","/CA.pem",
                "-servername","de.funti.cc","-connect",f"127.0.0.1:{port}"],input=raw,capture_output=True,timeout=5)
            finally:
                subprocess.run(["docker","rm","-f",client],capture_output=True)
            if result.returncode:raise OSError("verified TLS request failed: "+result.stderr[-300:].decode(errors="replace"))
            head,body=result.stdout.split(b"\r\n\r\n",1)
            lines=head.decode().split("\r\n")
            status=int(lines[0].split()[1])
            headers=dict(line.split(": ",1) for line in lines[1:])
            if headers.get("Transfer-Encoding")=="chunked":
                decoded=b""
                while True:
                    length,body=body.split(b"\r\n",1);length=int(length,16)
                    if not length:break
                    decoded+=body[:length];body=body[length+2:]
                body=decoded
            return status,body,headers.get("Cache-Control")

        nonce = os.urandom(32).hex()
        frame = {"nonce": nonce, "namespace": namespace, "operation": "Head"}
        frame["mac"] = tag(key, "witness-request-v1", compact([nonce, namespace, "Head"]))
        last_error = "no request"
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            try:
                status, raw, cache = request("/v1/witness", frame)
                if status == 200:
                    break
                last_error = "HTTP " + str(status) + ": " + raw[:200].decode(errors="replace")
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                last_error = type(error).__name__ + ": " + str(error)[:200]
            time.sleep(0.25)
        else:
            raise RuntimeError("Witness HTTPS startup failed: " + last_error + "; Caddy " + docker("logs", caddy)[-1000:] + "; witness " + docker("logs", witness)[-500:])
        reply = json.loads(raw)
        assert reply["nonce"] == nonce and cache == "no-store"
        assert hmac.compare_digest(reply["mac"], tag(key, "witness-response-v1", compact([nonce, reply["reply"]])))
        assert reply["reply"]["Head"] == {"namespace": namespace, "revision": 0, "event_highwater": 0, "digest": ""}
        frame["mac"] = "00" * 32
        assert request("/v1/witness", frame)[0] == 401, "unsigned witness access accepted"
        assert request("/private", frame)[0] == 404, "extra public route accepted"
        print("ACCOUNT_WITNESS_TLS_OK: verified certificate/hostname, published TLS port, private Caddy→witness, fresh signed head, invalid HMAC refused")
    finally:
        for container in reversed(containers):
            subprocess.run(["docker", "rm", "-f", container], capture_output=True)
        if network_created:
            subprocess.run(["docker", "network", "rm", prefix], capture_output=True)
        if ingress_created:
            subprocess.run(["docker", "network", "rm", prefix + "-ingress"], capture_output=True)
