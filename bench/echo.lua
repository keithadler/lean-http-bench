-- POST /echo with a 4 KiB body.
wrk.method = "POST"
wrk.body = string.rep("x", 4096)
wrk.headers["Content-Type"] = "application/octet-stream"
