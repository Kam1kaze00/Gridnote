package account

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

func openBrowser(u string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("/usr/bin/open", u)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	if err := cmd.Start(); err != nil {
		return errors.New("Could not open your browser for ChatGPT sign-in.")
	}
	go cmd.Wait()
	return nil
}

type tokens struct {
	Access   string `json:"access_token"`
	Refresh  string `json:"refresh_token"`
	Identity string `json:"id_token"`
	Scope    string `json:"scope"`
	Type     string `json:"token_type"`
	Lifetime int    `json:"expires_in"`
}

func (c client) form(ctx context.Context, endpoint string, values url.Values) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, "POST", c.auth+endpoint, strings.NewReader(values.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, errors.New("Could not reach ChatGPT. Check your connection and try again.")
	}
	return resp, nil
}

func (c client) token(ctx context.Context, form url.Values) (tokens, error) {
	var t tokens
	resp, err := c.form(ctx, "/api/accounts/oauth/token", form)
	if err != nil {
		return t, err
	}
	if resp.StatusCode == 400 {
		defer resp.Body.Close()
		var problem struct{ Error string }
		json.NewDecoder(io.LimitReader(resp.Body, 8192)).Decode(&problem)
		if problem.Error == "invalid_grant" {
			return t, errSession
		}
		return t, errors.New("ChatGPT could not authorize this connection. Try signing in again.")
	}
	err = readJSON(resp, &t)
	if err == nil && (t.Access == "" || t.Lifetime <= 0 || !strings.EqualFold(t.Type, "bearer")) {
		err = errors.New("ChatGPT returned an incomplete authorization.")
	}
	return t, err
}

func (c client) revoke(ctx context.Context, r registration) error {
	resp, err := c.form(ctx, "/api/accounts/oauth/revoke", url.Values{"token": {r.Refresh}, "token_type_hint": {"refresh_token"}, "client_id": {r.ClientID}})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return httpProblem(resp)
	}
	return nil
}

func (c client) refresh(ctx context.Context, path string, r *registration) error {
	if r.Refresh == "" {
		r.Access = ""
		if err := save(path, *r); err != nil {
			return err
		}
		return errSession
	}
	t, err := c.token(ctx, url.Values{"grant_type": {"refresh_token"}, "client_id": {r.ClientID}, "refresh_token": {r.Refresh}, "resource": {resource}})
	if err != nil {
		if errors.Is(err, errSession) {
			r.Access, r.Refresh = "", ""
			if e := save(path, *r); e != nil {
				return e
			}
		}
		return err
	}
	r.Access = t.Access
	r.Expiry = time.Now().Add(time.Duration(t.Lifetime) * time.Second)
	if t.Refresh != "" {
		r.Refresh = t.Refresh
	}
	if t.Scope != "" {
		r.Scope = t.Scope
	}
	if err := save(path, *r); err != nil {
		return err
	}
	if !r.connected() {
		return errors.New("ChatGPT plan access was declined. Click Ask AI to reconnect.")
	}
	return nil
}

func (c client) signIn(ctx context.Context, path string, r *registration) error {
	if r.Host == "" {
		var id [16]byte
		rand.Read(id[:])
		id[6] = (id[6] & 15) | 64
		id[8] = (id[8] & 63) | 128
		r.Host = fmt.Sprintf("urn:uuid:%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:])
		if err := save(path, *r); err != nil {
			return err
		}
	}
	state, nonce, verifier := randomText(), randomText(), randomText()
	hash := sha256.Sum256([]byte(verifier))
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return errors.New("Gridnote could not start the sign-in callback.")
	}
	defer listener.Close()
	redirect := "http://" + listener.Addr().String() + "/auth/callback"
	results := make(chan url.Values, 1)
	server := http.Server{ReadHeaderTimeout: 4 * time.Second, IdleTimeout: 4 * time.Second, MaxHeaderBytes: 16 << 10}
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		q := req.URL.Query()
		if req.Method != "GET" || req.Host != listener.Addr().String() || req.URL.Path != "/auth/callback" || q.Get("state") != state {
			http.Error(w, "Invalid sign-in callback.", 400)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintln(w, "Return to Gridnote to finish connecting your ChatGPT account.")
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		select {
		case results <- q:
		default:
		}
	})
	go server.Serve(listener)
	defer server.Close()
	form := url.Values{"client_id": {r.ClientID}, "ext_agent_host_id": {r.Host}, "response_type": {"code"}, "redirect_uri": {redirect}, "scope": {"openid profile email offline_access resource.invoke " + shareScope}, "resource": {resource}, "state": {state}, "nonce": {nonce}, "code_challenge_method": {"S256"}, "code_challenge": {base64.RawURLEncoding.EncodeToString(hash[:])}}
	if r.ClientID == "" {
		form.Set("client_id", "dynamic_agent_client")
		form.Set("agent_name_hint", "Gridnote")
	} else if r.IDToken != "" {
		form.Set("id_token_hint", r.IDToken)
	}
	if err = c.open(c.auth + "/api/accounts/authorize?" + form.Encode()); err != nil {
		return err
	}
	var q url.Values
	select {
	case q = <-results:
	case <-ctx.Done():
		return ctx.Err()
	}
	if q.Get("error") != "" {
		return errors.New("ChatGPT sign-in was canceled or declined. Your exercise is still here.")
	}
	issued := q.Get("client_id")
	if q.Get("code") == "" || (r.ClientID == "" && (issued == "" || issued == "dynamic_agent_client")) || (r.ClientID != "" && issued != "" && issued != r.ClientID) {
		return errors.New("ChatGPT returned an incomplete sign-in. Try again.")
	}
	if r.ClientID == "" {
		r.ClientID = issued
		if err = save(path, *r); err != nil {
			return err
		}
	}
	t, err := c.token(ctx, url.Values{"grant_type": {"authorization_code"}, "client_id": {r.ClientID}, "code": {q.Get("code")}, "code_verifier": {verifier}, "redirect_uri": {redirect}, "resource": {resource}})
	if err != nil {
		return err
	}
	verifyCtx := oidc.ClientContext(ctx, c.http)
	verifierOIDC := oidc.NewVerifier(c.auth, oidc.NewRemoteKeySet(verifyCtx, c.auth+"/.well-known/jwks.json"), &oidc.Config{ClientID: r.ClientID, SupportedSigningAlgs: []string{"RS256"}})
	identity, err := verifierOIDC.Verify(verifyCtx, t.Identity)
	if err != nil || identity.Nonce != nonce || identity.Subject == "" || (r.Subject != "" && r.Subject != identity.Subject) {
		return errors.New("Gridnote could not verify the ChatGPT account. Please sign in again.")
	}
	r.Subject, r.IDToken, r.Access, r.Refresh, r.Scope = identity.Subject, t.Identity, t.Access, t.Refresh, t.Scope
	r.Expiry = time.Now().Add(time.Duration(t.Lifetime) * time.Second)
	if err = save(path, *r); err != nil {
		return err
	}
	if !r.connected() {
		return errors.New("Signed in, but ChatGPT plan usage was not enabled. Choose Ask AI to review that permission.")
	}
	return nil
}
