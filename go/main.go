// The Go side of the benchmark: the same three endpoints as Main.lean, on net/http with its default settings.
package main

import (
	"flag"
	"io"
	"log"
	"net/http"
	"strconv"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8081", "listen address")
	flag.Parse()

	big := make([]byte, 256*1024)
	for i := range big {
		big[i] = byte(i % 251)
	}

	bigLen := strconv.Itoa(len(big))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("Hello, World!"))
	})
	mux.HandleFunc("POST /echo", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1024*1024))
		if err != nil {
			http.Error(w, err.Error(), http.StatusRequestEntityTooLarge)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.Write(body)
	})
	mux.HandleFunc("GET /big", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", bigLen)
		w.Write(big)
	})

	log.Printf("go http server on %s", *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}
