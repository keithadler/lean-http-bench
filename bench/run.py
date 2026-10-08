#!/usr/bin/env python3
"""Benchmark the Lean and Go HTTP servers with wrk, the same way.

Every scenario runs REPS times (default 3) on every server, interleaved so that each round starts with a different
server: the machine is not idle, and interleaving spreads that load over all of them. Each run is a warm-up that is
thrown away, then a measured run. Writes bench/results.json and prints a table of medians, with the range.

    bench/run.py                 (needs wrk; build the servers first with bench/build-servers.sh)
    REPS=5 DUR=10s bench/run.py
"""
import json, os, re, statistics, subprocess, sys, time, socket

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
REPS = int(os.environ.get("REPS", "3"))
DUR = os.environ.get("DUR", "8s")
WARM = os.environ.get("WARM", "2s")

SERVERS = [
    ("Lean 4.34.1 Std.Http", ["run/lean-http-server-v4.34.1", "--addr", "127.0.0.1:18180"], "127.0.0.1:18180"),
    ("Lean 4.34.1 + two workarounds", ["run/lean-http-server-v4.34.1", "--addr", "127.0.0.1:18181", "--fast-recv", "--own-date"],
     "127.0.0.1:18181"),
    ("Lean nightly-2026-10-08 Std.Http", ["run/lean-http-server-nightly", "--addr", "127.0.0.1:18182"], "127.0.0.1:18182"),
    ("Go net/http", ["go/go-http-server", "-addr", "127.0.0.1:18183"], "127.0.0.1:18183"),
]

# name, path, connections, wrk threads, extra wrk args
SCENARIOS = [
    ("GET /plaintext, 1 connection", "/plaintext", 1, 1, []),
    ("GET /plaintext, 64 connections", "/plaintext", 64, 4, []),
    ("POST /echo 4 KiB, 1 connection", "/echo", 1, 1, ["-s", "bench/echo.lua"]),
    ("POST /echo 4 KiB, 64 connections", "/echo", 64, 4, ["-s", "bench/echo.lua"]),
    ("GET /big 256 KiB, 8 connections", "/big", 8, 4, []),
]


def wait_port(addr):
    host, port = addr.split(":")
    for _ in range(100):
        try:
            socket.create_connection((host, int(port)), timeout=0.2).close()
            return
        except OSError:
            time.sleep(0.05)
    sys.exit(f"server on {addr} did not start")


def to_ms(s):
    m = re.match(r"([\d.]+)(us|ms|s)", s)
    v, u = float(m.group(1)), m.group(2)
    return v / 1000 if u == "us" else v * 1000 if u == "s" else v


def wrk(addr, path, conns, threads, extra, dur):
    out = subprocess.run(["wrk", f"-t{threads}", f"-c{conns}", f"-d{dur}", "--latency", *extra, f"http://{addr}{path}"],
                         capture_output=True, text=True, check=True).stdout
    rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
    p50 = to_ms(re.search(r"\s50%\s+(\S+)", out).group(1))
    p99 = to_ms(re.search(r"\s99%\s+(\S+)", out).group(1))
    errs = 0
    if m := re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", out):
        errs += sum(map(int, m.groups()))
    if m := re.search(r"Non-2xx or 3xx responses: (\d+)", out):
        errs += int(m.group(1))
    total = int(re.search(r"(\d+) requests in", out).group(1))
    return {"rps": round(rps), "p50Ms": round(p50, 3), "p99Ms": round(p99, 3), "errors": errs, "requests": total}


def main():
    procs = [subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for _, cmd, _ in SERVERS]
    try:
        for _, _, addr in SERVERS:
            wait_port(addr)
        rows = []
        for rep in range(1, REPS + 1):
            for sname, path, conns, threads, extra in SCENARIOS:
                n = len(SERVERS)
                for k in range(n):
                    name, _, addr = SERVERS[(k + rep) % n]
                    wrk(addr, path, conns, threads, extra, WARM)
                    r = {"server": name, "scenario": sname, "rep": rep, **wrk(addr, path, conns, threads, extra, DUR)}
                    print("  ", json.dumps(r), flush=True)
                    rows.append(r)
        json.dump(rows, open("bench/results.json", "w"), indent=1)
    finally:
        for p in procs:
            p.kill()

    print("\nMedian of the runs (range in brackets), requests per second; p99 latency is the median run's.\n")
    names = [s[0] for s in SERVERS]
    print("| Scenario | " + " | ".join(names) + " |")
    print("|---|" + "---:|" * len(names))
    for sname, *_ in SCENARIOS:
        cells = []
        for sv in names:
            rs = sorted((x for x in rows if x["scenario"] == sname and x["server"] == sv), key=lambda x: x["rps"])
            med = rs[len(rs) // 2]
            cells.append(f'{med["rps"]:,} [{rs[0]["rps"]:,}–{rs[-1]["rps"]:,}], p99 {med["p99Ms"]} ms')
        print(f"| {sname} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
