#!/usr/bin/env python3
"""Проверить только локальные проекты Compose и блок Caddy, без развёртывания."""
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
infra = root / "infra/funtidesk-account"
caddy_image = "caddy@sha256:748016f285ed8c43a9ce6e3aed6d92d3009d90ca41157950880f40beaf3ff62b"


def run(*arguments, data=None):
    result = subprocess.run(arguments, input=data, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError("Local configuration validation failed: " + arguments[0])
    return result.stdout


account = json.loads(run("docker", "compose", "--env-file", str(infra / ".env.example"),
                         "-f", str(infra / "compose.yaml"), "config", "--format", "json"))
assert all(not service.get("ports") for service in account["services"].values())
assert set(account["services"]["account"]["networks"]) == {"frontend", "smtp", "witness"}
assert set(account["services"]["mail"]["networks"]) == {"smtp", "outbound"}
mail_mounts = {mount["target"]: mount for mount in account["services"]["mail"]["volumes"]}
assert mail_mounts["/usr/local/bin/funtidesk-mail"]["read_only"]
assert mail_mounts["/usr/local/bin/funtidesk-mail"]["source"] == str(infra / "mail-entrypoint.sh")
assert (infra / "mail-entrypoint.sh").stat().st_mode & 0o111
assert account["networks"]["frontend"]["internal"] and account["networks"]["smtp"]["internal"]
assert account["networks"]["witness"]["internal"]
relay = account["services"]["witness-relay"]
assert set(relay["networks"]) == {"witness", "witness-outbound"}
assert not relay.get("volumes") and relay["command"] == ["witness-relay"]
assert account["services"]["account"]["environment"]["FUNTI_ACCOUNT_WITNESS_URL"] == "http://funtidesk-account-witness-relay:21801/v1/witness"
assert account["services"]["account"]["environment"]["FUNTI_ACCOUNT_TRUSTED_PROXIES"] == "172.31.251.4"

# Only the inspected Caddy service fields are reproduced; no VPN configuration or secrets.
with tempfile.TemporaryDirectory(prefix="funtidesk-compose-check-") as temporary:
    base = pathlib.Path(temporary) / "base.yaml"
    base.write_text("""services:
  caddy:
    image: caddy:local-config-check
    networks: [remnawave-network]
    volumes:
      - /opt/remnawave/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - /opt/funtidesk-web/current:/usr/share/caddy:ro
      - caddy-ssl-data:/data
networks:
  remnawave-network:
    external: true
    name: remnawave-network
volumes:
  caddy-ssl-data: {}
""")
    merged = json.loads(run("docker", "compose", "--env-file", str(infra / ".env.example"),
                            "-f", str(base), "-f", str(infra / "caddy-account.override.yaml"),
                            "config", "--format", "json"))
    service = merged["services"]["caddy"]
    assert set(service["networks"]) == {"remnawave-network", "funtidesk-account-front"}
    assert service["networks"]["funtidesk-account-front"]["ipv4_address"] == "172.31.251.4"
    assert service["image"] == "caddy:local-config-check"
    mounts = {mount["target"]: mount for mount in service["volumes"]}
    assert mounts["/etc/caddy/Caddyfile"]["read_only"] and mounts["/usr/share/caddy"]["read_only"]
    assert mounts["/data"]["source"] == "caddy-ssl-data"

adapted = json.loads(run("docker", "run", "--rm", "-i", "--network", "none", "--entrypoint", "sh",
                         caddy_image, "-c", "cat > /tmp/Caddyfile; caddy adapt --config /tmp/Caddyfile --adapter caddyfile --validate",
                         data=(infra / "Caddyfile.desk.proposed").read_text()))
assert adapted["apps"]["http"]["servers"]
witness = json.loads(run("docker", "compose", "--env-file", str(infra / ".env.witness.example"),
                        "-f", str(infra / "compose.witness.yaml"), "config", "--format", "json"))
assert not witness["services"]["witness"].get("ports")
assert set(witness["services"]["witness"]["networks"]) == {"witness"}
assert witness["networks"]["witness"]["internal"]
assert set(witness["services"]["caddy"]["networks"]) == {"witness", "ingress"}
assert not witness["networks"]["ingress"].get("internal")
assert witness["services"]["caddy"]["cap_add"] == ["NET_BIND_SERVICE"]
assert witness["services"]["caddy"]["ports"][0]["published"] == "8447"
assert set(witness["services"]["witness"]["environment"]).isdisjoint({"FUNTI_ACCOUNT_KEY_FILE", "FUNTI_ACCOUNT_DATABASE"})
with tempfile.TemporaryDirectory(prefix="funtidesk-witness-tls-check-") as temporary:
    cert = pathlib.Path(temporary)
    run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-subj", "/CN=de.funti.cc", "-keyout", str(cert / "privkey.pem"), "-out", str(cert / "fullchain.pem"))
    adapted = json.loads(run("docker", "run", "--rm", "-i", "--network", "none", "-v", str(cert) + ":/certs:ro", "--entrypoint", "sh",
                             caddy_image, "-c", "cat > /tmp/Caddyfile; caddy adapt --config /tmp/Caddyfile --adapter caddyfile --validate",
                             data=(infra / "Caddyfile.witness.proposed").read_text()))
    assert adapted["apps"]["http"]["servers"]
print("ACCOUNT_COMPOSE_CADDY_CHECK_OK: isolated API/mail/witness, relay without secrets, only witness TLS port, proposed Caddy blocks valid")
