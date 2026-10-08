import Std.Http
import FastRecv

open Std.Async Std.Http

/-! The Lean side of the benchmark: three endpoints on Lean's own HTTP/1.1 server, `Std.Http`.

- `GET /plaintext` answers `Hello, World!` (the fixed cost of a request).
- `POST /echo` reads the request body and sends it back (reading and writing a body).
- `GET /big` answers 256 KiB (throughput). -/

/-- 256 KiB of a repeating pattern, made once. -/
def bigBody : ByteArray := ByteArray.mk ((Array.range (256 * 1024)).map fun i => UInt8.ofNat (i % 251))

def pathOf (target : RequestTarget) : String :=
  match target with
  | .originForm path _ => toString path
  | _ => ""

/-- An HTTP `Date` value (RFC 9110 IMF-fixdate), made from `Std.Time`'s built-in UTC rules instead of loading the
UTC zone from the time-zone database on each call, as `DateTime.nowAt "UTC"` does. `toRFC822String` ends in `+0000`;
HTTP requires `GMT` there. -/
def httpDate : IO String := do
  let s := (Std.Time.DateTime.ofTimestamp (← Std.Time.Timestamp.now) Std.Time.TimeZone.ZoneRules.UTC).toRFC822String
  return if s.endsWith " +0000" then (s.dropEnd 6).toString ++ " GMT" else s

/-- `ownDate`: the handler sets `Date` itself with `httpDate` (and the server is told not to). -/
def handle (big : ByteArray) (ownDate : Bool) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let ok ← if ownDate then pure (Response.ok |>.header! "Date" (← httpDate)) else pure Response.ok
  match req.line.method, pathOf req.line.uri with
  | .get, "/plaintext" => ok |>.text "Hello, World!"
  | .post, "/echo" =>
    let body : ByteArray ← req.body.readAll (maximumSize := some (1024 * 1024))
    ok |>.bytes body
  | .get, "/big" => ok |>.bytes big
  | _, _ => Response.notFound |>.text "not found"

/-- `lean-http-server [--addr 127.0.0.1:8080] [--max-requests N] [--no-date] [--own-date] [--fast-recv]`: serve until killed. `--max-requests` is how many
requests one keep-alive connection may carry before the server closes it; `Std.Http`'s default is 100. `--no-date` leaves out the `Date` header;
`--own-date` has the handler write it with `httpDate` instead of `Std.Http`. `--fast-recv` runs `Std.Http`'s own connection loop
(`serveConnection`) over a transport whose read selector does not block a worker thread (`FastRecv.lean`). -/
def main (args : List String) : IO Unit := do
  let rec opt (name : String) (dflt : String) : List String → String
    | a :: b :: rest => if a == name then b else opt name dflt (b :: rest)
    | _ => dflt
  let addr := opt "--addr" "127.0.0.1:8080" args
  let some maxRequests := (opt "--max-requests" "100" args).toNat?
    | throw (IO.userError "--max-requests must be a number")
  let some (host, port) := (match addr.splitOn ":" with
      | [h, p] => p.toNat?.map (h, ·)
      | _ => none) | throw (IO.userError s!"--addr must be host:port, not {addr}")
  let some ip := Std.Net.IPv4Addr.ofString host | throw (IO.userError s!"{host} is not an IPv4 address")
  let ownDate := args.contains "--own-date"
  let generateDate := !args.contains "--no-date" && !ownDate
  let big := bigBody
  let config : Config := { maxRequests, generateDate }
  if args.contains "--fast-recv" then
    Async.block do
      let server ← Std.Async.TCP.Socket.Server.mk
      server.bind (.v4 { addr := ip, port := port.toUInt16 })
      server.listen 1024
      server.noDelay
      IO.eprintln s!"lean http server (fast recv) on {addr}, {maxRequests} requests per connection"
      while true do
        let client ← server.accept
        background (Server.serveConnection (FastClient.mk client) (Server.Handler.ofFn (handle big ownDate)) config).run
    return
  Async.block do
    let server ← Server.serve (.v4 { addr := ip, port := port.toUInt16 }) (Server.Handler.ofFn (handle big ownDate))
      config
    IO.eprintln s!"lean http server on {addr}, {maxRequests} requests per connection"
    server.waitShutdown
