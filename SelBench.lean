import Std.Async
import Std.Async.TCP
import FastRecv

open Std.Async Std.Async.TCP

/-! Where `Std.Http`'s per-request time goes: a minimal HTTP/1.1 keep-alive server that answers every request with
`Hello, World!`, reading the socket in one of five ways.

- `recv`:      `sock.recv?`, nothing else.
- `select`:    `Selectable.one` over `sock.recvSelector` alone.
- `timer`:     `Selectable.one` over `sock.recvSelector` and a `Selector.sleep`, as `Std.Http` waits for each read.
- `nb`:        the same, with a read selector whose winning read does not block a worker thread (`recvSelectorNB`).
- `nb-notry`:  `nb`, without the readiness probe in `tryFn`. -/

def response : ByteArray :=
  "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 13\r\n\r\nHello, World!".toUTF8

/-- How many request heads (`\r\n\r\n`) end in `b`. wrk does not pipeline, so this is one per read in practice. -/
def heads (b : ByteArray) : Nat := Id.run do
  let mut n := 0
  for i in [3:b.size] do
    if b[i - 3]! == 13 && b[i - 2]! == 10 && b[i - 1]! == 13 && b[i]! == 10 then n := n + 1
  return n

def readWith (mode : String) (sock : Socket.Client) : Async (Option ByteArray) := do
  match mode with
  | "recv" => sock.recv? 8192
  | "select" => Selectable.one #[.case (sock.recvSelector 8192) pure]
  | "timer" => Selectable.one #[.case (sock.recvSelector 8192) pure, .case (← Selector.sleep 12000) fun _ => pure none]
  | "nb" => Selectable.one #[.case (recvSelectorNB sock 8192 true) pure, .case (← Selector.sleep 12000) fun _ => pure none]
  | _ => Selectable.one #[.case (recvSelectorNB sock 8192 false) pure, .case (← Selector.sleep 12000) fun _ => pure none]

partial def serve (mode : String) (sock : Socket.Client) : Async Unit := do
  let some chunk ← readWith mode sock | return
  for _ in [0:heads chunk] do sock.send response
  serve mode sock

/-- `sel-bench MODE [--addr 127.0.0.1:8090]` -/
def main (args : List String) : IO Unit := do
  let mode := args.headD "recv"
  unless ["recv", "select", "timer", "nb", "nb-notry"].contains mode do
    throw (IO.userError s!"unknown mode {mode}")
  let addr := match args with | _ :: "--addr" :: a :: _ => a | _ => "127.0.0.1:8090"
  let some (host, port) := (match addr.splitOn ":" with
      | [h, p] => p.toNat?.map (h, ·)
      | _ => none) | throw (IO.userError s!"--addr must be host:port, not {addr}")
  let some ip := Std.Net.IPv4Addr.ofString host | throw (IO.userError s!"{host} is not an IPv4 address")
  Async.block do
    let server ← Socket.Server.mk
    server.bind (.v4 { addr := ip, port := port.toUInt16 })
    server.listen 1024
    IO.eprintln s!"sel-bench {mode} on {addr}"
    while true do
      let client ← server.accept
      client.noDelay
      background (serve mode client)
