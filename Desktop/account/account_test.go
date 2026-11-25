package account

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAccountExercise(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	b64 := base64.RawURLEncoding.EncodeToString
	var host, nonce, challenge, redirect string
	var mismatch, deny bool
	var asks, logins, refreshes, revokes int
	sign := func(v any) string {
		claims, _ := json.Marshal(v)
		data := b64([]byte(`{"kid":"test","alg":"RS256"}`)) + "." + b64(claims)
		digest := sha256.Sum256([]byte(data))
		sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
		if err != nil {
			panic(err)
		}
		return data + "." + b64(sig)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/.well-known/jwks.json":
			json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]string{"kid": "test", "kty": "RSA", "alg": "RS256", "n": b64(key.N.Bytes()), "e": b64(big.NewInt(int64(key.E)).Bytes())}}})
		case "/api/accounts/oauth/token":
			if r.FormValue("client_id") != "issued-account" || r.FormValue("resource") != resource {
				t.Error("wrong token exchange identity")
			}
			access, refresh := "access1", "refresh1"
			if r.FormValue("grant_type") == "refresh_token" {
				refreshes++
				if r.FormValue("refresh_token") != "refresh1" {
					t.Error("did not use current refresh token")
				}
				access, refresh = "access2", "refresh2"
			} else {
				pkce := sha256.Sum256([]byte(r.FormValue("code_verifier")))
				if r.FormValue("redirect_uri") != redirect || b64(pkce[:]) != challenge || r.FormValue("code") != "one-time" {
					t.Error("code/redirect/PKCE mismatch")
				}
			}
			n := nonce
			if mismatch {
				n = "wrong"
			}
			scope := "openid " + shareScope
			if deny {
				scope = "openid"
			}
			json.NewEncoder(w).Encode(map[string]any{"id_token": sign(map[string]any{"iss": host, "aud": "issued-account", "sub": "student", "nonce": n, "exp": time.Now().Add(time.Hour).Unix()}), "access_token": access, "refresh_token": refresh, "expires_in": 3600, "scope": scope, "token_type": "Bearer"})
		case "/models":
			if r.Header.Get("Authorization") != "Bearer access2" {
				t.Error("model catalog used wrong account token")
			}
			io.WriteString(w, `{"models":[{"slug":"hidden","visibility":"hide"},{"slug":"text","visibility":"list","input_modalities":["text"]},{"slug":"eligible","visibility":"list","input_modalities":["text","image"]}]}`)
		case "/responses":
			asks++
			var body struct {
				Model         string
				Store, Stream bool
				Input         []struct{ Content []map[string]string }
			}
			json.NewDecoder(r.Body).Decode(&body)
			if !body.Stream || body.Store || body.Model != "eligible" || r.Header.Get("Authorization") != "Bearer access2" || len(body.Input) != 1 || len(body.Input[0].Content) != 2 || body.Input[0].Content[0]["text"] != "5x + 4 = 3" {
				t.Error("incorrect exercise payload")
			}
			fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"x = -0.2\"}\n\ndata: {\"type\":\"response.completed\"}\n\n")
		case "/api/accounts/oauth/revoke":
			revokes++
			if r.FormValue("token") != "refresh2" {
				t.Error("did not revoke rotated refresh token")
			}
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	host = server.URL
	c := client{http: server.Client(), auth: host, api: host}
	c.open = func(s string) error {
		u, _ := url.Parse(s)
		q := u.Query()
		nonce, challenge, redirect = q.Get("nonce"), q.Get("code_challenge"), q.Get("redirect_uri")
		if logins == 0 && (q.Get("agent_name_hint") != "Gridnote" || q.Get("client_id") != "dynamic_agent_client") {
			t.Error("wrong app registration")
		}
		if logins > 0 && q.Get("client_id") != "issued-account" {
			t.Error("lost issued client ID")
		}
		logins++
		wrong, err := http.Get(redirect + "?state=wrong&code=unexpected")
		if err != nil {
			return err
		}
		wrong.Body.Close()
		if wrong.StatusCode != 400 {
			t.Error("accepted unrelated callback")
		}
		res, err := http.Get(redirect + "?" + url.Values{"state": {q.Get("state")}, "code": {"one-time"}, "client_id": {"issued-account"}}.Encode())
		if err == nil {
			res.Body.Close()
		}
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	dir := t.TempDir()
	path := filepath.Join(dir, "account.json")
	perform := func(action string) (Reply, error) {
		return c.run(ctx, dir, Request{Action: action, Text: "5x + 4 = 3", Image: "data:image/jpeg;base64,/9j/"})
	}
	mismatch = true
	if r, err := perform("connect"); err == nil || r.Connected {
		t.Fatal("accepted incorrect ID-token nonce")
	}
	mismatch = false
	deny = true
	if r, err := perform("connect"); err == nil || r.Connected {
		t.Fatal("treated identity-only sign-in as plan consent")
	}
	if _, err := perform("ask"); err == nil || asks != 0 {
		t.Fatal("sent an exercise without consent")
	}
	deny = false
	if r, err := perform("connect"); err != nil || !r.Connected {
		t.Fatal(r, err)
	}
	var reg registration
	d, _ := os.ReadFile(path)
	json.Unmarshal(d, &reg)
	reg.Expiry = time.Now()
	if err = save(path, reg); err != nil {
		t.Fatal(err)
	}
	if r, err := perform("ask"); err != nil || r.Answer != "x = -0.2" || asks != 1 || refreshes != 1 {
		t.Fatal(r, err)
	}
	if r, err := perform("disconnect"); err != nil || r.Connected || revokes != 1 {
		t.Fatal(r, err)
	}
	if _, err := perform("ask"); err == nil || asks != 1 {
		t.Fatal("sent an exercise after disconnect")
	}
	if _, err := readAnswer(strings.NewReader("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n")); err == nil {
		t.Fatal("accepted interrupted answer")
	}
}
