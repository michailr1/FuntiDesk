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
assert set(account["services"]["account"]["networks"]) == {"frontend", "smtp"}
assert set(account["services"]["mail"]["networks"]) == {"smtp", "outbound"}
assert account["networks"]["frontend"]["internal"] and account["networks"]["smtp"]["internal"]
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
print("ACCOUNT_COMPOSE_CADDY_CHECK_OK: private ports, isolated networks, existing mounts retained, proposed desk block valid")
