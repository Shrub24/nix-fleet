#!/usr/bin/env python3
"""Run the module's generated startup path and test its configuration authority."""

import json
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
    for cycle in range(2):
        subprocess.run(["bash", "-e", "-c", launch["preStart"]], check=True)
        assert json.loads(target.read_text()) == expected, "startup config was not restored"
        assert stat.S_IMODE(target.stat().st_mode) == 0o400, "config permissions drifted"
        log_path = app / f"cycle-{cycle}.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_ready(process, base + "/health", log_path)
            config_request = urllib.request.Request(
                base + "/api/config",
                data=json.dumps({"client_config": {"drop_excess_requests": True}}).encode(),
                headers={"Content-Type": "application/json"},
                method="PUT",
            )
            try:
                urllib.request.urlopen(config_request, timeout=10).close()
                raise AssertionError("management API accepted a core config mutation")
            except urllib.error.HTTPError as error:
                detail = error.read().decode()
                assert error.code == 500 and "Config store not initialized" in detail, detail
            body = {
                "provider": "mutation-probe",
                "custom_provider_config": {
                    "base_provider_type": "openai",
                    "allowed_requests": {"embedding": True, "list_models": False},
                },
            }
            request = urllib.request.Request(
                base + "/api/providers",
                data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            try:
                urllib.request.urlopen(request, timeout=10).close()
                raise AssertionError("management API accepted a provider mutation")
            except urllib.error.HTTPError as error:
                detail = error.read().decode()
                assert error.code == 500 and "config store not found" in detail, detail
            with urllib.request.urlopen(base + "/api/providers", timeout=10) as response:
                assert "mutation-probe" not in response.read().decode(), "refused mutation survived"
            assert json.loads(target.read_text()) == expected, "API changed startup config"
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
        "core config mutation refused; provider mutation refused and rolled back; startup config restored\n"
    )


if __name__ == "__main__":
    main()
