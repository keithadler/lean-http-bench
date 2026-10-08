import Std.Async
import Std.Async.TCP
import Std.Http

open Std.Async Std.Async.TCP

/-! A fix for `Std.Async.TCP.Socket.Client.recvSelector`, and an `Std.Http` transport that uses it. -/

/-- `recvSelector` from `Std.Async.TCP`, except that once it has won, the read runs as a promise instead of
`(s.recv? size).block` on a worker thread. Data is still only taken after winning, so nothing is lost. -/
def recvSelectorNB (s : Socket.Client) (size : UInt64) (probe : Bool) : Selector (Option ByteArray) where
  tryFn := do
    if !probe then return none
    let readable ← s.native.waitReadable
    if ← readable.isResolved then
      return some (← s.recv? size)
    else
      s.native.cancelRecv
      return none
  registerFn waiter := do
    let readable ← s.native.waitReadable
    discard <| IO.mapTask (t := readable.result?) fun res => do
      match res with
      | none => return ()
      | some res =>
        waiter.race (return ()) fun promise => do
          match res with
          | .error e => promise.resolve (.error e)
          | .ok _ =>
            let p ← s.native.recv? size
            discard <| IO.mapTask (t := p.result?) fun r => do
              match r with
              | some r => promise.resolve r
              | none => promise.resolve (.error (.userError "read cancelled"))
  unregisterFn := s.native.cancelRecv

/-- A TCP client whose `Std.Http` transport reads through `recvSelectorNB`. -/
structure FastClient where
  sock : Socket.Client

instance : Std.Http.Transport FastClient where
  recv c expect := c.sock.recv? expect
  sendAll c data := c.sock.sendAll data
  recvSelector c expect := recvSelectorNB c.sock expect true
