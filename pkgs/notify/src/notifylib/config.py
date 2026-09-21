"""Shared configuration loading for the notify tools."""

import json
import logging
import os

log = logging.getLogger("notify")

CONFIG_FILE = os.environ.get("NOTIFY_CONFIG_FILE", "/etc/notify/config.json")


def load():
    """Load dispatch config; None when absent (tools degrade to CLI-only)."""
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        log.warning("notify config not found at %s; dispatch disabled", CONFIG_FILE)
        return None



def events_file():
    return os.environ.get("NOTIFY_EVENTS_FILE", "/etc/notify/events.json")
