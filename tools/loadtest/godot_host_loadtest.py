#!/usr/bin/env python3
"""Load test for the headless Godot lobby host (docs/tech/loadtest.md).

For each client count: start `godot --headless ... host_main.gd -- --host`,
run the Go bot (`server/cmd/bot -input=wander`) against it for --duration,
sample the host's CPU and RSS from /proc, and collect the host's HOST_STATS
line (tick time percentiles, skipped ticks, snapshot bytes).

Linux only (/proc). Usage:
  tools/loadtest/godot_host_loadtest.py [--clients 8,25,50] [--duration 60]
"""
import argparse
import json
import os
import platform
import re
import socket
import subprocess
import sys
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLK_TCK = os.sysconf("SC_CLK_TCK")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def proc_cpu_seconds(pid):
    with open(f"/proc/{pid}/stat") as f:
        fields = f.read().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / CLK_TCK  # utime + stime


def proc_status_kb(pid, key):
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith(key + ":"):
                return int(line.split()[1])
    return 0


def box_info():
    model = "unknown"
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    model = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    mem_kb = 0
    try:
        with open("/proc/meminfo") as f:
            mem_kb = int(f.readline().split()[1])
    except OSError:
        pass
    return {
        "nproc": os.cpu_count(),
        "cpu_model": model,
        "mem_gib": round(mem_kb / 1048576, 1),
        "kernel": platform.release(),
        "loadavg_before": open("/proc/loadavg").read().split()[:3],
    }


def run_one(args, clients):
    port = free_port()
    host_cmd = [args.godot, "--headless", "--path", os.path.join(ROOT, "client"),
                "-s", "res://src/net/host/host_main.gd", "--",
                "--host", "--port", str(port), "--expect-clients", str(clients),
                "--emitters", str(args.emitters), "--exit-when-empty",
                "--run-seconds", str(args.duration + 60)]
    host = subprocess.Popen(host_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = []
    ready = threading.Event()

    def pump():
        for line in host.stdout:
            lines.append(line.rstrip("\n"))
            if line.startswith("HOST_READY"):
                ready.set()
    threading.Thread(target=pump, daemon=True).start()
    if not ready.wait(30):
        host.kill()
        raise SystemExit("host did not print HOST_READY:\n" + "\n".join(lines))

    url = f"ws://127.0.0.1:{port}/ws"
    bot_cmd = [args.bot, "-url", url, "-clients", str(clients), "-duration", f"{args.duration}s",
               "-input", "wander", "-seed", "1", "-mult", "1.0"]
    bot = subprocess.Popen(bot_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    # Skip connect/warm-up, then sample CPU and RSS over the steady window.
    warm = min(5.0, args.duration / 4)
    time.sleep(warm)
    cpu0, t0 = proc_cpu_seconds(host.pid), time.monotonic()
    bot_cpu0 = proc_cpu_seconds(bot.pid) if bot.poll() is None else 0.0
    rss_max = 0
    cpu1, t1, bot_cpu1, hwm = cpu0, t0, bot_cpu0, 0
    while bot.poll() is None:
        try:
            rss_max = max(rss_max, proc_status_kb(host.pid, "VmRSS"))
            cpu1, t1 = proc_cpu_seconds(host.pid), time.monotonic()
            bot_cpu1 = proc_cpu_seconds(bot.pid)
            hwm = proc_status_kb(host.pid, "VmHWM")
        except (OSError, IndexError):
            pass
        time.sleep(0.5)
    bot_out = bot.stdout.read()
    try:
        host.wait(30)
    except subprocess.TimeoutExpired:
        host.kill()
    stats_line = next((l for l in lines if l.startswith("HOST_STATS ")), None)
    if stats_line is None:
        raise SystemExit("host printed no HOST_STATS:\n" + "\n".join(lines[-40:]))
    stats = json.loads(stats_line.split(" ", 1)[1])
    window = max(t1 - t0, 1e-9)
    stats.update({
        "clients": clients,
        "bot_exit": bot.returncode,
        "bot_output": bot_out.strip(),
        "host_cpu_pct": round(100 * (cpu1 - cpu0) / window, 1),
        "host_rss_mib_max": round(rss_max / 1024, 1),
        "host_vmhwm_mib": round(hwm / 1024, 1),
        "bot_cpu_pct": round(100 * (bot_cpu1 - bot_cpu0) / window, 1),
    })
    return stats


def ms(us):
    return f"{us / 1000:.2f}"


def table(results):
    rows = ["| clients | live bullets (avg) | tick p50 / p95 / p99 / max (ms) | net-in / sim / encode / send p50 (ms) "
            "| achieved Hz | skipped ticks | snapshot B/client/s (wire stub) | projected full-state B/client/s "
            "| host CPU % (of one core) | host RSS MiB (max) | bot ok |",
            "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        t = r["tick_us"]
        rows.append("| {c} | {b:.0f} | {p50} / {p95} / {p99} / {mx} | {ni} / {si} / {en} / {se} | {hz} | {sk} | {sb:,.0f} | {fb:,.0f} | {cpu} | {rss} | {ok} |".format(
            c=r["clients"], b=r["bullets_avg"], p50=ms(t["p50"]), p95=ms(t["p95"]), p99=ms(t["p99"]), mx=ms(t["max"]),
            ni=ms(r["net_in_us"]["p50"]), si=ms(r["sim_us"]["p50"]), en=ms(r["encode_us"]["p50"]), se=ms(r["send_us"]["p50"]),
            hz=r["achieved_tick_hz"], sk=r["skipped_ticks"], sb=r["snapshot_bytes_per_client_s"],
            fb=r["full_state_bytes_per_client_s"], cpu=r["host_cpu_pct"], rss=r["host_rss_mib_max"],
            ok="yes" if r["bot_exit"] == 0 else f"no ({r['bot_exit']})"))
    return "\n".join(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clients", default="8,25,50")
    ap.add_argument("--duration", type=int, default=60, help="bot -duration in seconds per run")
    ap.add_argument("--emitters", type=int, default=20)
    ap.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    ap.add_argument("--bot", default=os.path.join(ROOT, ".tools", "bin", "er-bot-loadtest"))
    ap.add_argument("--out", default=os.path.join(ROOT, "loadtest-results"))
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.bot), exist_ok=True)
    subprocess.run(["go", "build", "-o", args.bot, "./cmd/bot"], cwd=os.path.join(ROOT, "server"), check=True)
    subprocess.run([args.godot, "--headless", "--path", os.path.join(ROOT, "client"), "--import"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    version = subprocess.run([args.godot, "--version"], capture_output=True, text=True).stdout.strip()

    info = box_info()
    info["godot"] = version
    results = []
    for n in [int(x) for x in args.clients.split(",") if x]:
        print(f"== {n} clients, {args.duration}s", flush=True)
        r = run_one(args, n)
        print(f"   tick p50={ms(r['tick_us']['p50'])}ms p99={ms(r['tick_us']['p99'])}ms "
              f"max={ms(r['tick_us']['max'])}ms skipped={r['skipped_ticks']} cpu={r['host_cpu_pct']}% "
              f"rss={r['host_rss_mib_max']}MiB bot_exit={r['bot_exit']}", flush=True)
        results.append(r)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "results.json"), "w") as f:
        json.dump({"box": info, "duration_s": args.duration, "results": results}, f, indent=2)
    md = table(results)
    with open(os.path.join(args.out, "results.md"), "w") as f:
        f.write(md + "\n")
    print(json.dumps(info))
    print(md)
    if any(r["bot_exit"] != 0 for r in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
