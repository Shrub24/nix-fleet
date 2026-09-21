{ python3, writeScriptBin }:

writeScriptBin "notify" ''
  #!${python3}/bin/python3
  """CLI for the notification daemon.

  Usage:
    notify <tier> [title] [type] [topic]   Send a notification (stdin = body)
    notify test [--topic TOPIC] [--tier TIER]   Send test via daemon
    notify test --direct [--topic TOPIC]        Test ntfy server directly
  """
  import argparse
  import json
  import os
  import sys
  import urllib.request
  import urllib.error

  DAEMON_URL = os.environ.get("NOTIFY_URL", "http://127.0.0.1:5555")

  def send_via_daemon(tier, title, ntype, topic, message):
      url = "%s/notify" % DAEMON_URL
      payload = json.dumps({
          "tier": tier, "title": title, "type": ntype,
          "topic": topic, "message": message,
      }).encode()
      req = urllib.request.Request(
          url, data=payload, headers={"Content-Type": "application/json"},
      )
      try:
          resp = urllib.request.urlopen(req, timeout=15)
          data = json.loads(resp.read().decode())
          return resp.status, data
      except urllib.error.HTTPError as e:
          body = e.read().decode()
          try:
              detail = json.loads(body)
          except (ValueError, KeyError):
              detail = body
          return e.code, {"error": detail}
      except (urllib.error.URLError, OSError) as e:
          return None, {"error": str(e)}

  def test_via_daemon(topic, tier):
      url = "%s/debug/test-notify" % DAEMON_URL
      payload = json.dumps({"topic": topic, "tier": tier}).encode()
      req = urllib.request.Request(
          url, data=payload, headers={"Content-Type": "application/json"},
      )
      try:
          resp = urllib.request.urlopen(req, timeout=15)
          data = json.loads(resp.read().decode())
          return resp.status, data
      except urllib.error.HTTPError as e:
          body = e.read().decode()
          try:
              detail = json.loads(body)
          except (ValueError, KeyError):
              detail = body
          return e.code, {"error": detail}
      except (urllib.error.URLError, OSError) as e:
          return None, {"error": str(e)}

  def test_direct(topic):
      url = "%s/debug/ntfy-check?topic=%s" % (DAEMON_URL, topic)
      req = urllib.request.Request(url, method="GET")
      try:
          resp = urllib.request.urlopen(req, timeout=15)
          data = json.loads(resp.read().decode())
          return resp.status, data
      except urllib.error.HTTPError as e:
          body = e.read().decode()
          try:
              detail = json.loads(body)
          except (ValueError, KeyError):
              detail = body
          return e.code, {"error": detail}
      except (urllib.error.URLError, OSError) as e:
          return None, {"error": str(e)}

  def print_result(status, data):
      if status is None:
          print("FAIL  daemon unreachable: %s" % data.get("error", "unknown"), file=sys.stderr)
          sys.exit(1)

      ok = status < 300 and data.get("test_result") != "fail"
      label = "OK" if ok else "FAIL"
      print("[%s] HTTP %d" % (label, status))

      if "steps" in data:
          for step in data["steps"]:
              step_status = "ok" if step.get("ok") else "ERR"
              line = "  %-10s  %s" % ("[%s]" % step_status, step.get("label", ""))
              if step.get("detail"):
                  line += "  — %s" % step["detail"]
              print(line)

      if data.get("errors"):
          for err in data["errors"]:
              print("  error: %s" % err)

      if not ok:
          sys.exit(1)

  # Legacy mode: positional args.
  if len(sys.argv) >= 2 and sys.argv[1] not in ("test", "-h", "--help"):
      tier = sys.argv[1]
      title = sys.argv[2] if len(sys.argv) > 2 else "Notification"
      ntype = sys.argv[3] if len(sys.argv) > 3 else "info"
      topic = sys.argv[4] if len(sys.argv) > 4 else None
      body = sys.stdin.read()
      status, data = send_via_daemon(tier, title, ntype, topic, body)
      if status is None:
          sys.exit("notification daemon connection failed: %s" % data.get("error"))
      if status >= 300:
          errs = data.get("errors", data.get("error", data))
          sys.exit("notification daemon error: %d %s" % (status, errs))
      sys.exit(0)

  # Subcommand mode.
  parser = argparse.ArgumentParser(
      prog="notify",
      description="Send notifications via the notification daemon",
  )
  sub = parser.add_subparsers(dest="command")

  test_p = sub.add_parser("test", help="Send a test notification")
  test_p.add_argument("--topic", default="system", help="ntfy topic (default: system)")
  test_p.add_argument("--tier", default="info", help="Notification tier (default: info)")
  test_p.add_argument(
      "--direct", action="store_true",
      help="Test ntfy server directly (bypasses daemon dispatch, tests auth + connectivity)",
  )

  args = parser.parse_args()

  if args.command == "test":
      if args.direct:
          print("Testing ntfy server directly (topic=%s)..." % args.topic)
          status, data = test_direct(args.topic)
      else:
          print("Sending test notification via daemon (topic=%s, tier=%s)..." % (args.topic, args.tier))
          status, data = test_via_daemon(args.topic, args.tier)
      print_result(status, data)
  else:
      parser.print_help()
      sys.exit(1)
''
