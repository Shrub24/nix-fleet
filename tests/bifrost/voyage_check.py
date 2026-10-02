#!/usr/bin/env python3
"""Exercise the loaded Voyage hook through Bifrost's real embedding route."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class MockProvider(BaseHTTPRequestHandler):
    bodies = []

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        self.bodies.append(json.loads(self.rfile.read(size)))
        payload = json.dumps(
            {
                "object": "list",
                "data": [{"object": "embedding", "embedding": [0.1, 0.2], "index": 0}],
                "model": "voyage-4",
                "usage": {"prompt_tokens": 1, "total_tokens": 1},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_ready(process, url, log_path):
    import urllib.error
    import urllib.request

    for _ in range(120):
        if process.poll() is not None:
            raise RuntimeError(f"Bifrost exited {process.returncode}: {log_path.read_text()[-5000:]}")
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                if response.status == 200 and json.loads(response.read()).get("status") == "ok":
                    return
        except (OSError, urllib.error.URLError):
            time.sleep(0.25)
    raise RuntimeError(f"Bifrost did not become healthy: {log_path.read_text()[-5000:]}")


def request(base, model, fields, extra_params=None):
    import urllib.error
    import urllib.request

    body = {"model": model, "input": "plugin contract probe", **fields}
    headers = {"Content-Type": "application/json"}
    if extra_params is not None:
        body["extra_params"] = extra_params
        headers["x-bf-passthrough-extra-params"] = "true"
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        base + "/v1/embeddings",
        data=data,
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            if response.status != 200:
                raise RuntimeError(f"embedding request returned HTTP {response.status}")
            json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"embedding request returned HTTP {error.code}: {detail}") from error


def main():
    binary, plugin_path, output = sys.argv[1:]
    provider = ThreadingHTTPServer(("127.0.0.1", 0), MockProvider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    provider_url = f"http://127.0.0.1:{provider.server_port}/v1/embeddings"
    app_port = free_port()

    with tempfile.TemporaryDirectory(prefix="bifrost-voyage-check-") as tmp:
        root = Path(tmp)
        app_dir = root / "app"
        feeds = root / "feeds"
        app_dir.mkdir()
        feeds.mkdir()
        (feeds / "pricing.json").write_text(
            '{"gpt-4o-mini":{"provider":"openai","mode":"chat",'
            '"input_cost_per_token":0.00000015,"output_cost_per_token":0.0000006}}'
        )
        (feeds / "model-parameters.json").write_text(
            '{"gpt-4o-mini":{"supports_reasoning":false,"supports_sampling_params":true}}'
        )
        (feeds / "mcp-library.json").write_text('{"servers":[]}')

        custom = {
            "custom_provider_config": {
                "base_provider_type": "openai",
                "allowed_requests": {"list_models": False, "embedding": True},
                "request_path_overrides": {"embedding": provider_url},
            },
            "network_config": {"base_url": provider_url.rsplit("/", 1)[0]},
            "keys": [{"name": "fixture", "value": "local-test-key", "models": ["*"]}],
        }
        config = {
            "framework": {
                "pricing": {
                    "pricing_url": f"file://{feeds / 'pricing.json'}",
                    "model_parameters_url": f"file://{feeds / 'model-parameters.json'}",
                    "mcp_library_url": f"file://{feeds / 'mcp-library.json'}",
                }
            },
            "providers": {"voyage": custom, "other": custom},
            "plugins": [
                {
                    "enabled": True,
                    "name": "voyage-normalizer",
                    "path": plugin_path,
                    "placement": "post_builtin",
                }
            ],
        }
        (app_dir / "config.json").write_text(json.dumps(config))
        log_path = root / "bifrost.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [binary, "-app-dir", str(app_dir), "-host", "127.0.0.1", "-port", str(app_port)],
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        base = f"http://127.0.0.1:{app_port}"
        try:
            wait_ready(process, base + "/health", log_path)
            request(
                base,
                "voyage/voyage-4",
                {"encoding_format": "float", "dimensions": 256, "input_type": "query"},
            )
            request(
                base,
                "voyage/voyage-4",
                {"encoding_format": "base64", "dimensions": 256},
                {"output_dimension": 512, "input_type": "document"},
            )
            request(
                base,
                "other/model-1",
                {"encoding_format": "float", "dimensions": 384},
            )
            bodies = MockProvider.bodies
            if len(bodies) != 3:
                raise AssertionError(f"expected 3 provider requests, received {len(bodies)}: {bodies!r}")

            normalized, native_wins, untouched = bodies
            if "encoding_format" in normalized or "dimensions" in normalized:
                raise AssertionError(f"Voyage float/dimensions not normalized: {normalized!r}")
            if normalized.get("output_dimension") != 256:
                raise AssertionError(f"Voyage mapping lost values: {normalized!r}")

            if native_wins.get("encoding_format") != "base64" or "dimensions" in native_wins:
                raise AssertionError(f"non-float/native dimensions not handled: {native_wins!r}")
            if native_wins.get("output_dimension") != 512 or native_wins.get("input_type") != "document":
                raise AssertionError(f"explicit output_dimension or extra parameter was lost: {native_wins!r}")

            if untouched.get("encoding_format") != "float" or untouched.get("dimensions") != 384:
                raise AssertionError(f"non-Voyage request was mutated: {untouched!r}")

            Path(output).mkdir(parents=True)
            (Path(output) / "request-bodies.json").write_text(json.dumps(bodies, indent=2) + "\n")
            (Path(output) / "summary.txt").write_text(
                "loaded-plugin=voyage-normalizer\n"
                "voyage-float=encoding_format removed; dimensions mapped to output_dimension\n"
                "voyage-explicit-output_dimension=preserved; dimensions removed; base64 preserved\n"
                "other-provider=body unchanged\n"
                f"outbound-bodies={json.dumps(bodies, sort_keys=True)}\n"
            )
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            provider.shutdown()
            provider.server_close()


if __name__ == "__main__":
    main()
