"""Stream native-runner diagnostics; a shutdown can prevent artifact upload."""

import os
from pathlib import Path
import shutil
import subprocess
import time

while True:
    memory = dict(
        line.split(":", 1) for line in Path("/proc/meminfo").read_text().splitlines()
    )
    vm = dict(line.split() for line in Path("/proc/vmstat").read_text().splitlines())
    disk = shutil.disk_usage("/nix/store")
    print(
        f"ci resources {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}: "
        f"MemAvailable={memory['MemAvailable'].strip()} "
        f"MemTotal={memory['MemTotal'].strip()} "
        f"SwapFree={memory['SwapFree'].strip()} "
        f"SwapTotal={memory['SwapTotal'].strip()} "
        f"oom_kill={vm['oom_kill']} "
        f"store_free_MiB={disk.free // 2**20} load={os.getloadavg()}",
        flush=True,
    )
    # Include compilers and VMs, not just the Nix client. Avoid command arguments.
    processes = subprocess.run(
        ["ps", "-eo", "pid,ppid,comm,rss,pcpu", "--sort=-rss"],
        capture_output=True,
        text=True,
        check=True,
    )
    print("\n".join(processes.stdout.splitlines()[:16]), flush=True)
    subprocess.run(
        ["ps", "-C", "nix,nix-daemon,nix-eval-jobs", "-o", "pid,ppid,comm,rss,pcpu"],
        check=False,
    )
    for name in ("memory.current", "memory.max", "memory.events"):
        path = Path("/sys/fs/cgroup") / name
        if path.exists():
            print(f"cgroup {name}: {path.read_text().strip()}", flush=True)
    time.sleep(15)
