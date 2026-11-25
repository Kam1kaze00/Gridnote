// Gridnote's desktop launcher serves the embedded offline editor on loopback.
// A stable origin allows the default browser to reopen its existing local library.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"mime"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

//go:embed site
var assets embed.FS

const address = "127.0.0.1:48765"
const origin = "http://" + address
const identity = "Gridnote standalone v1"

func openEditor() error {
	switch runtime.GOOS {
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", origin).Start()
	case "darwin":
		return exec.Command("open", origin).Start()
	default:
		return exec.Command("xdg-open", origin).Start()
	}
}

func explain(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost || r.Header.Get("Origin") != origin || r.Header.Get("X-Gridnote-Request") != "1" {
		http.Error(w, `{"error":"Open the notebook on this device to ask for an explanation."}`, 403)
		return
	}
	body := http.MaxBytesReader(w, r.Body, 3200000)
	defer body.Close()
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, "http://127.0.0.1:8765/api/explain", body)
	if err != nil {
		http.Error(w, `{"error":"Invalid exercise."}`, 400)
		return
	}
	req.ContentLength = r.ContentLength
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Gridnote-Request", "1")
	client := &http.Client{Timeout: 85 * time.Second}
	reply, err := client.Do(req)
	if err != nil {
		http.Error(w, `{"error":"Use Copy to ChatGPT, or start the optional local study server."}`, 503)
		return
	}
	defer reply.Body.Close()
	w.WriteHeader(reply.StatusCode)
	io.Copy(w, io.LimitReader(reply.Body, 200000))
}

// Read only product labels reported by the local OS. No device access prompt is needed.
func detectedDevice(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	var names []string
	switch runtime.GOOS {
	case "linux":
		files, _ := filepath.Glob("/sys/class/input/event*/device/name")
		for _, f := range files {
			if data, err := os.ReadFile(f); err == nil {
				names = append(names, strings.TrimSpace(string(data)))
			}
		}
	case "windows":
		ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
		defer cancel()
		data, _ := exec.CommandContext(ctx, "powershell", "-NoProfile", "-NonInteractive", "-Command", "Get-PnpDevice -PresentOnly -Class HIDClass,Mouse | Select-Object -ExpandProperty FriendlyName").Output()
		names = strings.Split(string(data), "\n")
	}
	device := map[string]string{}
	for _, name := range names {
		name = strings.TrimSpace(name)
		s := strings.ToLower(name)
		if strings.Contains(s, "keyboard") || strings.Contains(s, "pad pad") {
			continue
		}
		profile := ""
		switch {
		case strings.Contains(s, "wacom"):
			profile = "wacom"
		case strings.Contains(s, "huion") || strings.Contains(s, "kamvas"):
			profile = "huion"
		case strings.Contains(s, "xp-pen") || strings.Contains(s, "xppen"):
			profile = "xppen"
		case strings.Contains(s, "xencelabs"):
			profile = "xencelabs"
		case strings.Contains(s, "surface pen"):
			profile = "surface"
		}
		if profile != "" {
			device = map[string]string{"profile": profile, "name": name}
			break
		}
	}
	json.NewEncoder(w).Encode(device)
}

func main() {
	noOpen := flag.Bool("no-open", false, "serve the notebook without opening a browser")
	flag.Parse()
	listener, err := net.Listen("tcp4", address)
	if err != nil {
		client := &http.Client{Timeout: time.Second}
		response, getErr := client.Get(origin + "/_gridnote")
		if getErr == nil {
			defer response.Body.Close()
			data, _ := io.ReadAll(io.LimitReader(response.Body, 64))
			if string(data) == identity {
				if !*noOpen {
					openEditor()
				}
				return
			}
		}
		log.Fatal(err)
	}
	site, err := fs.Sub(assets, "site")
	if err != nil {
		log.Fatal(err)
	}
	mime.AddExtensionType(".mjs", "text/javascript")
	mime.AddExtensionType(".wasm", "application/wasm")
	mime.AddExtensionType(".webmanifest", "application/manifest+json")
	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(http.FS(site)))
	mux.HandleFunc("/_gridnote", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, identity) })
	mux.HandleFunc("/api/explain", explain)
	mux.HandleFunc("/_gridnote-device", detectedDevice)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != address {
			http.Error(w, "Unknown host", 403)
			return
		}
		mux.ServeHTTP(w, r)
	}), ReadHeaderTimeout: 8 * time.Second}
	fmt.Println("Gridnote is open at", origin)
	if !*noOpen {
		if err := openEditor(); err != nil {
			fmt.Println("Open the address above in your browser.")
		}
	}
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
