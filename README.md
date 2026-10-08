# lean-http-bench

How fast is Lean's own HTTP server, `Std.Http`? The same three endpoints, on `Std.Http` and on Go's `net/http`,
measured with [wrk](https://github.com/wg/wrk) on one machine.

| Endpoint | What it measures |
|---|---|
| `GET /plaintext` | `Hello, World!`: the fixed cost of a request |
| `POST /echo` | reads a 4 KiB body and sends it back |
| `GET /big` | a 256 KiB reply: throughput |

| File | What it is |
|---|---|
| `Main.lean` | The Lean server, on `Std.Http`'s `Server.serve`, with flags for the workarounds below. |
| `go/main.go` | The Go server: `net/http` and `ServeMux`, default settings. |
| `FastRecv.lean` | A read selector that does not block a worker thread, and an `Std.Http` transport that uses it. |
| `SelBench.lean` | A minimal keep-alive server that reads the socket five ways, to find where the time goes. |
| `bench/check.sh` | Checks a server's answers: bodies byte for byte, status codes, 300 requests on one connection. |
| `bench/build-servers.sh`, `bench/run.py` | Build the servers for each Lean toolchain, and run the benchmark. |

## Building and checking

```bash
bench/build-servers.sh                       # needs elan and Go; builds with Lean 4.34.1 and nightly-2026-10-08 into run/
run/lean-http-server-v4.34.1 --addr 127.0.0.1:8080 &
bench/check.sh 127.0.0.1:8080
bench/run.py                                 # needs wrk
```

Every server passes `bench/check.sh`.

## Results

Requests per second, median of three runs, range in brackets; p99 latency is the median run's.

| Scenario | Lean 4.34.1 `Std.Http` | Lean 4.34.1 + two workarounds | Lean nightly-2026-10-08 `Std.Http` | Go `net/http` |
|---|---:|---:|---:|---:|
| `GET /plaintext`, 1 connection | 3,670 [3,641–3,696], p99 0.37 ms | 5,089 [5,063–5,245], p99 0.27 ms | 4,834 [4,759–5,018], p99 0.28 ms | **48,220** [47,544–49,216], p99 0.06 ms |
| `GET /plaintext`, 64 connections | 2,388 [2,349–2,566], p99 40.2 ms | 9,353 [9,207–10,851], p99 8.7 ms | 9,827 [9,096–11,678], p99 8.5 ms | **170,865** [167,120–196,437], p99 3.0 ms |
| `POST /echo` 4 KiB, 1 connection | 2,842 [2,653–2,866], p99 0.44 ms | 3,439 [3,383–3,515], p99 0.38 ms | 3,436 [3,314–3,558], p99 0.38 ms | **41,616** [39,591–41,810], p99 0.06 ms |
| `POST /echo` 4 KiB, 64 connections | 1,829 [1,820–2,138], p99 56.8 ms | 6,094 [5,989–7,084], p99 12.5 ms | 6,702 [6,495–8,107], p99 11.5 ms | **89,550** [88,037–100,724], p99 4.2 ms |
| `GET /big` 256 KiB, 8 connections | 3,429 [3,404–3,542], p99 3.5 ms | 6,527 [6,413–7,130], p99 1.8 ms | 7,114 [6,908–7,282], p99 1.7 ms | **28,964** [28,615–29,192], p99 0.45 ms |

- **Lean 4.34.1** is the latest stable release.
- **nightly-2026-10-08** has three fixes that are on Lean's master branch but in no release yet, v4.35.0-rc4 included:
  [#15174](https://github.com/leanprover/lean4/pull/15174) (among other things, the socket read selector no longer
  blocks a worker thread), [#15443](https://github.com/leanprover/lean4/pull/15443) (the `Date` header without the
  time-zone database) and [#15469](https://github.com/leanprover/lean4/pull/15469) (`Date` in the `GMT` form HTTP
  requires).
- **The two workarounds** get 4.34.1 to about where the nightly is, without changing Lean. Both are in this
  repository: `--fast-recv` serves connections with `Std.Http`'s own `serveConnection` over a transport whose read
  selector does not block (`FastRecv.lean`), and `--own-date` has the handler set `Date` itself (`httpDate` in
  `Main.lean`), which `Std.Http` then leaves alone.

## What the numbers say

- **On the stable release, Go answers 13 to 72 times as many requests** (8 times on the 256 KiB download). Worst is
  many connections at once: with 64, `Std.Http` 4.34.1 answers *fewer* requests than with one.
- **The fixes already on master help a lot under load:** about 4 times as many small requests with 64 connections,
  twice the throughput on the large reply, and p99 latency down from 40–57 ms to 8.5–11.5 ms. One request at a time they add
  20 to 30%.
- **Go is still 10 to 17 times faster on small requests after them,** and 4 times on the large reply. Upstream knows:
  [lean4#13469](https://github.com/leanprover/lean4/issues/13469), opened by Sofia Rodrigues, who wrote `Std.Http`, traces it to
  synchronization in Lean's runtime (the task manager's single lock, several mutexes per request, atomic reference
  counts). Fixing it means redesigning the task manager and event loop, and the Lean team has said that is not a fit
  for outside contributions.
- **It is not Lean code being slow.** A keep-alive loop of plain `recv?` calls on the same `Std.Async` sockets answers
  62,000 requests a second at 64 connections (below), and the gRPC server in
  [lean-grpc-sqlite](https://github.com/keithadler/lean-grpc-sqlite), which also talks to sockets directly, beats
  grpc-go under load. The cost is in how `Std.Http` waits: every read races a timer and other events through
  `Selectable.one`, and each of those steps goes through the task manager.
- **If you run `Std.Http` on 4.34.1 today,** the two workarounds here are worth taking; the nightly makes them
  unnecessary.

## Where the time goes

Profiling under 64 connections (macOS `sample`, on 4.33.0, whose `Std.Http` and `Std.Async` code here is the same
as 4.34.1's) shows almost no time in the server's own code. Nearly every
sample is a thread waiting on the task manager's lock, and the process starts more and more worker threads (56 at
the peak). Two causes, both fixed on master:

1. **The read selector blocks a worker thread.** `Socket.Client.recvSelector`, which `Std.Http` uses for every read,
   reads with `(s.recv? size).block` once it has won the race, inside a task. Each waiting connection holds a worker
   thread, so the task manager starts more threads, and they all contend for its lock.
2. **The `Date` header loads the time-zone database for every response.** `DateTime.nowAt "UTC"` opens and parses
   `/usr/share/zoneinfo/UTC` each time. Building the time from `TimeZone.ZoneRules.UTC` gives identical text for
   100,000 instants from 1970 to 2243, at about a 19th of the cost (measured in the interpreter). (It also wrote `+0000` where HTTP requires `GMT`.)

`SelBench.lean` isolates the first: a minimal keep-alive server that answers `Hello, World!`, reading the socket four
ways, on 4.34.1. Requests per second, median of three interleaved 5-second runs (`bench/results-selbench.json`):

| How each read waits | 1 connection | 64 connections |
|---|---:|---:|
| `recv?` on its own | 21,279 | 62,036 |
| `Selectable.one` over `recvSelector` | 12,448 | 4,064 |
| the same, racing a timer, as `Std.Http` does | 11,195 | 3,488 |
| the same, with a read selector that does not block (`FastRecv.lean`) | 9,928 | 23,515 |

The blocking read is what makes concurrency *lower* throughput; without it, 64 connections answer nearly seven times
as many. The rest of the distance to plain `recv?` is the cost of `Selectable.one` and the timer, the subject of
#13469.

## Method

Apple M3 (8 cores), macOS, loopback, wrk on the same machine. Every scenario runs three times on every server,
interleaved so that each round starts with a different server: the machine was not idle (load average around 5),
and interleaving spreads that over all of them. Each run is a 2-second warm-up, thrown away, then 8 seconds
measured. `bench/results.json` has every run. Both servers send the same headers (`Content-Type`, `Content-Length`,
`Date`); `Std.Http` also sends `Server: LeanHTTP/1.1`. No run had a socket error or a non-2xx reply.
