// The Mac app uses one private stdin/stdout exchange. Credentials stay in package account.
package main

import (
	"context"
	"encoding/json"
	"github.com/Kam1kaze00/Gridnote/desktop/account"
	"io"
	"os"
	"time"
)

func main() {
	reply := account.Reply{Error: "Gridnote could not read this exercise."}
	var req account.Request
	if json.NewDecoder(io.LimitReader(os.Stdin, 14<<20)).Decode(&req) == nil {
		timeout := 2 * time.Minute
		if req.Action == "connect" {
			timeout = 5 * time.Minute
		}
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		reply = account.Run(ctx, req)
	}
	json.NewEncoder(os.Stdout).Encode(reply)
}
