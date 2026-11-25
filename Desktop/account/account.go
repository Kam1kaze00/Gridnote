// Package account connects Gridnote to its own user-authorized ChatGPT session.
package account

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/gofrs/flock"
)

const issuer = "https://auth.openai.com"
const resource = "https://api.openai.com/v1"
const shareScope = "chatgpt.tokens.use.direct"

type Request struct {
	Action string `json:"action"`
	Text   string `json:"text,omitempty"`
	Image  string `json:"image,omitempty"`
	Kind   string `json:"kind,omitempty"`
}
type Reply struct {
	Connected bool   `json:"connected"`
	Answer    string `json:"answer,omitempty"`
	Error     string `json:"error,omitempty"`
}
type registration struct {
	Host, ClientID, Subject, IDToken, Access, Refresh, Scope string
	Expiry                                                   time.Time
}

// Keep credentials in Gridnote's private user directory, outside notebooks and web storage.
func directory() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	if runtime.GOOS == "windows" && os.Getenv("LOCALAPPDATA") != "" {
		base = os.Getenv("LOCALAPPDATA")
	}
	return filepath.Join(base, "Gridnote", "ChatGPT"), nil
}

func randomText() string {
	var b [32]byte
	rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}

func (r registration) connected() bool {
	return r.Access != "" && strings.Contains(" "+r.Scope+" ", " "+shareScope+" ")
}

func save(path string, r registration) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".account-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	err = json.NewEncoder(f).Encode(r)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}

type client struct {
	http      *http.Client
	auth, api string
	open      func(string) error
}

func Run(ctx context.Context, req Request) Reply {
	dir, err := directory()
	if err != nil {
		return Reply{Error: "Gridnote could not open its account settings."}
	}
	c := client{http: &http.Client{Timeout: 2 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, auth: issuer, api: resource, open: openBrowser}
	reply, err := c.run(ctx, dir, req)
	if err != nil {
		switch {
		case errors.Is(err, context.Canceled):
			reply.Error = "Request canceled."
		case errors.Is(err, context.DeadlineExceeded):
			reply.Error = "The request timed out. Try Ask AI again."
		default:
			reply.Error = err.Error()
		}
	}
	return reply
}

func (c client) run(ctx context.Context, dir string, req Request) (Reply, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return Reply{}, err
	}
	path := filepath.Join(dir, "account.json")
	lock := flock.New(filepath.Join(dir, "account.lock"))
	ok, err := lock.TryLockContext(ctx, 100*time.Millisecond)
	if !ok || err != nil {
		return Reply{}, errors.New("Another Gridnote account request is still running.")
	}
	locked := true
	defer func() {
		if locked {
			lock.Unlock()
		}
	}()
	var r registration
	data, err := os.ReadFile(path)
	if err == nil {
		if json.Unmarshal(data, &r) != nil {
			return Reply{}, errors.New("Gridnote could not read its saved ChatGPT connection.")
		}
	} else if !os.IsNotExist(err) {
		return Reply{}, err
	}
	switch req.Action {
	case "status":
		return Reply{Connected: r.connected()}, nil
	case "connect":
		if !r.connected() {
			if err = c.signIn(ctx, path, &r); err != nil {
				return Reply{}, err
			}
		}
		return Reply{Connected: r.connected()}, nil
	case "disconnect":
		var revokeErr error
		if r.Refresh != "" {
			revokeErr = c.revoke(ctx, r)
		}
		r.Access, r.Refresh, r.IDToken, r.Scope = "", "", "", ""
		if err = save(path, r); err != nil {
			return Reply{}, err
		}
		if revokeErr != nil {
			return Reply{}, errors.New("Disconnected on this device. Open ChatGPT settings to finish revoking access.")
		}
		return Reply{}, nil
	case "ask":
		if err = validateExercise(req); err != nil {
			return Reply{}, err
		}
		if !r.connected() {
			return Reply{}, errors.New("Choose Continue with ChatGPT to enable Ask AI.")
		}
		if time.Until(r.Expiry) < 2*time.Minute {
			if err = c.refresh(ctx, path, &r); err != nil {
				return Reply{Connected: r.connected()}, err
			}
		}
		lock.Unlock()
		locked = false
		answer, err := c.explain(ctx, r.Access, req)
		if errors.Is(err, errSession) {
			// A rejected access token may already have been replaced by another instance.
			// Invalidate only the matching token and keep its registration for reauthorization.
			if held, _ := lock.TryLockContext(ctx, 100*time.Millisecond); held {
				locked = true
				data, readErr := os.ReadFile(path)
				var latest registration
				if readErr == nil && json.Unmarshal(data, &latest) == nil && latest.Access == r.Access {
					latest.Access = ""
					if err := save(path, latest); err != nil {
						return Reply{}, err
					}
				}
			}
			return Reply{}, err
		}
		return Reply{Answer: answer, Connected: true}, err
	default:
		return Reply{}, errors.New("Unknown Gridnote account action.")
	}
}

var errSession = errors.New("Your ChatGPT connection needs attention. Click Ask AI to sign in again.")

func validateExercise(r Request) error {
	if len(r.Text) > 64000 || (strings.TrimSpace(r.Text) == "" && r.Image == "") {
		return errors.New("Select one exercise or a cropped image.")
	}
	if r.Image != "" {
		encoded, ok := strings.CutPrefix(r.Image, "data:image/jpeg;base64,")
		if !ok || len(encoded) > 12<<20 {
			return errors.New("Select a smaller image crop.")
		}
		raw, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil || len(raw) < 3 || raw[0] != 0xff || raw[1] != 0xd8 || raw[2] != 0xff {
			return errors.New("Gridnote could not read the selected image.")
		}
	}
	return nil
}

func readJSON(resp *http.Response, target any) error {
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return httpProblem(resp)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(target)
}

func httpProblem(resp *http.Response) error {
	switch resp.StatusCode {
	case 401:
		return errSession
	case 403:
		return errors.New("Your ChatGPT plan or workspace has not enabled this request. Review Gridnote’s access in ChatGPT settings.")
	case 429:
		return errors.New("ChatGPT’s usage limit was reached. Open Manage usage or try again later.")
	default:
		return fmt.Errorf("ChatGPT could not complete the request (HTTP %d). Try again shortly.", resp.StatusCode)
	}
}
