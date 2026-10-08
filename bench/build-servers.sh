#!/usr/bin/env bash
# Build the servers the benchmark compares, into run/:
#   run/lean-http-server-v4.34.1    Std.Http from the latest stable Lean
#   run/lean-http-server-nightly    Std.Http from a nightly with the fixes that are on master but not yet released
#   go/go-http-server               net/http
# Each Lean toolchain builds a copy of the sources in run/build-<name>, so the checkout's own .lake is left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p run
build() {  # name toolchain
  local dir="run/build-$1"
  rm -rf "$dir"; mkdir -p "$dir"
  cp lakefile.toml Main.lean FastRecv.lean SelBench.lean "$dir/"
  echo "$2" > "$dir/lean-toolchain"
  (cd "$dir" && lake build lean-http-server sel-bench 2>&1 | tail -1)
  cp "$dir/.lake/build/bin/lean-http-server" "run/lean-http-server-$1"
  cp "$dir/.lake/build/bin/sel-bench" "run/sel-bench-$1"
}
build v4.34.1 "leanprover/lean4:v4.34.1"
build nightly "leanprover/lean4-nightly:nightly-2026-10-08"
(cd go && go build -o go-http-server .)
ls -la run/lean-http-server-* go/go-http-server
