#!/usr/bin/env python3
"""Run the module's generated startup path and test its configuration authority."""

import json
import os
import shlex
import socket
import stat
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

from voyage_check import wait_ready


def main():
    launch = json.loads(Path(sys.argv[1]).read_text())
    app = Path(launch["dataDir"])
    app.mkdir(mode=0o700)
    target = app / "config.json"
    expected = json.loads(Path(launch["configFile"]).read_text())
    command = shlex.split(launch["command"])
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    command[command.index("-port") + 1] = str(port)
    base = f"http://127.0.0.1:{port}"
    logs = []
    setup_token = "bifrost-module-check-setup-token"
    headers = {"X-Bifrost-Setup-Token": setup_token}
    environment = dict(os.environ, BIFROST_SETUP_TOKEN=setup_token)
    for cycle in range(2):
        subprocess.run(["bash", "-e", "-c", launch["preStart"]], check=True)
        assert json.loads(target.read_text()) == expected, "startup config was not restored"
        assert stat.S_IMODE(target.stat().st_mode) == 0o400, "config permissions drifted"
        log_path = app / f"cycle-{cycle}.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=environment)
        try:
            wait_ready(process, base + "/health", log_path)
            try:
                urllib.request.urlopen(base + "/api/routing/rules", timeout=10)
            except urllib.error.HTTPError as error:
                assert error.code == 401, error.code
            else:
                raise AssertionError("anonymous routing API access was allowed")
            request = urllib.request.Request(base + "/api/routing/rules", headers=headers)
            with urllib.request.urlopen(request, timeout=10) as response:
                rules = json.loads(response.read())
                assert "fixture-cel" in json.dumps(rules), rules
            # Governance must be enabled, not merely bypassed by a health probe.
            request = urllib.request.Request(base + "/api/governance/virtual-keys", headers=headers)
            with urllib.request.urlopen(request, timeout=10) as response:
                assert response.status == 200
            assert json.loads(target.read_text()) == expected, "runtime changed startup config"
        finally:
            process.terminate()
            process.wait(timeout=20)
        logs.append(log_path)
        # A stale on-disk document must never become the next startup authority.
        target.chmod(0o600)
        target.write_text('{"config_store":{"enabled":true}}')
    output = Path(sys.argv[2])
    output.mkdir()
    for log in logs:
        (output / log.name).write_bytes(log.read_bytes())
    (output / "summary.txt").write_text(
        "generated startup path healthy on fresh state and restart\n"
        "governance and CEL routing available; startup config restored\n"
    )


if __name__ == "__main__":
    main()
