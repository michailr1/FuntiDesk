#!/usr/bin/env python3
# Managed by FuntiDesk scripts/account/install-witness-tls.sh
"""Проверить и передать сертификат существующего Caddy своему HTTPS-сервису."""
import argparse
import fcntl
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid


def run(*arguments, data=None):
    result = subprocess.run(arguments, input=data, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError("TLS operation failed: " + arguments[0])
    return result.stdout


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def copy_file(source, destination, maximum, private):
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as incoming:
        metadata = os.fstat(incoming.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > maximum:
            raise RuntimeError("Invalid TLS source file")
        if metadata.st_mode & (0o077 if private else 0o022):
            raise RuntimeError("Unsafe TLS source permissions")
        contents = incoming.read(maximum + 1)
    if not contents or len(contents) > maximum:
        raise RuntimeError("Invalid TLS source size")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as outgoing:
        outgoing.write(contents)
        outgoing.flush()
        os.fsync(outgoing.fileno())


def validate(directory, ca_file=None):
    certificate = str(directory / "fullchain.pem")
    private = str(directory / "privkey.pem")
    run("openssl", "x509", "-in", certificate, "-noout", "-checkend", "86400")
    arguments = ["openssl", "verify", "-purpose", "sslserver", "-verify_hostname", "de.funti.cc"]
    if ca_file:
        arguments.extend(["-CAfile", str(ca_file)])
    run(*arguments, "-untrusted", certificate, certificate)
    public = run("openssl", "x509", "-in", certificate, "-pubkey", "-noout")
    matching = run("openssl", "pkey", "-in", private, "-passin", "pass:", "-pubout")
    if public != matching:
        raise RuntimeError("TLS certificate and key mismatch")


def docker(*arguments):
    return run("docker", "--host=unix:///var/run/docker.sock", *arguments).decode().strip()


def running_caddy(project):
    containers = docker("ps", "--filter", "label=com.docker.compose.project=" + project,
                        "--filter", "label=com.docker.compose.service=caddy", "--format", "{{.ID}}").split()
    if len(containers) > 1:
        raise RuntimeError("Ambiguous witness Caddy service")
    if containers:
        if docker("inspect", "--format", "{{.HostConfig.NetworkMode}}", containers[0]) == "host":
            raise RuntimeError("Witness Caddy must not use host network")
        return containers[0]
    return None


def reload_caddy(container):
    # --force is required: identical JSON still has to reread changed TLS files.
    docker("exec", container, "caddy", "reload", "--force", "--address", "127.0.0.1:2019",
           "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile")


def set_current(directory, generation):
    temporary = directory / (".current-" + uuid.uuid4().hex)
    temporary.symlink_to(generation)
    os.replace(temporary, directory / "current")
    sync_directory(directory)


def synchronize(certificate, private, directory, project="funtidesk-account-witness", ca_file=None):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", project):
        raise RuntimeError("Invalid Compose project")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = directory.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
        raise RuntimeError("TLS directory must be owned by this user with mode 0700")
    descriptor = os.open(directory / ".sync.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        previous = None
        current = directory / "current"
        if current.is_symlink():
            previous = os.readlink(current)
            if not re.fullmatch(r"generation-[0-9a-f]{32}", previous):
                raise RuntimeError("Invalid current TLS generation")
            if not (directory / previous).is_dir() or (directory / previous).is_symlink():
                raise RuntimeError("Missing current TLS generation")
        elif current.exists():
            raise RuntimeError("TLS current path must be managed symlink")
        for name in ["fullchain.pem", "privkey.pem"]:
            path = directory / name
            if path.is_symlink():
                if os.readlink(path) != "current/" + name:
                    raise RuntimeError("Unexpected TLS file link")
            elif path.exists():
                raise RuntimeError("Existing TLS files require explicit migration")
        stage = Path(tempfile.mkdtemp(prefix=".stage-", dir=directory))
        generation = None
        published = False
        try:
            copy_file(certificate, stage / "fullchain.pem", 1024 * 1024, False)
            copy_file(private, stage / "privkey.pem", 64 * 1024, True)
            validate(stage, ca_file)
            if previous and all((stage / name).read_bytes() == (directory / previous / name).read_bytes()
                                for name in ["fullchain.pem", "privkey.pem"]):
                return "unchanged"
            container = running_caddy(project)
            generation = "generation-" + uuid.uuid4().hex
            sync_directory(stage)
            os.replace(stage, directory / generation)
            for name in ["fullchain.pem", "privkey.pem"]:
                link = directory / name
                if not link.is_symlink():
                    link.symlink_to("current/" + name)
            set_current(directory, generation)
            published = True
            if container:
                reload_caddy(container)
            keep = {generation, previous}
            for path in directory.iterdir():
                if re.fullmatch(r"generation-[0-9a-f]{32}", path.name) and path.name not in keep:
                    if path.is_dir() and not path.is_symlink():
                        shutil.rmtree(path)
            sync_directory(directory)
            return "updated and reloaded" if container else "updated; Caddy not running"
        except Exception:
            if published:
                if previous:
                    set_current(directory, previous)
                else:
                    current.unlink(missing_ok=True)
                    sync_directory(directory)
            if generation:
                shutil.rmtree(directory / generation, ignore_errors=True)
            raise
        finally:
            shutil.rmtree(stage, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--certificate", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--project", default="funtidesk-account-witness")
    arguments = parser.parse_args()
    try:
        result = synchronize(arguments.certificate, arguments.key, arguments.directory, arguments.project)
        print("WITNESS_TLS_SYNC_OK: " + result)
    except Exception as error:
        # Never forward subprocess stderr, private material or a traceback into journald.
        reason = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("WITNESS_TLS_SYNC_FAILED: " + reason, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
