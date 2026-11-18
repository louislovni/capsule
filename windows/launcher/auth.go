package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	firebaseAPIKey = "AIzaSyDcwS9Uahx5i8XaUzHmQy2J7dHZbHAj694" // the web app's (public; Firestore rules protect the data)
	projectID      = "capsule-bbb39"
	referer        = "https://louislovni.github.io/"
)

// Account: a signed-in Firebase user, its token refreshed when needed.
type Account struct {
	UID          string `json:"uid"`
	Email        string `json:"email"`
	RefreshToken string `json:"refreshToken"`
	idToken      string
	expires      time.Time
	path         string
}

func sessionPath(dir string) string { return filepath.Join(dir, "capsule", "compte.json") }

func signIn(dir string) (*Account, error) {
	path := sessionPath(dir)
	if data, err := os.ReadFile(path); err == nil {
		var a Account
		if json.Unmarshal(data, &a) == nil && a.RefreshToken != "" {
			a.path = path
			if _, err := a.Token(); err == nil {
				fmt.Printf("Compte : %s\n\n", a.Email)
				return &a, nil
			} else if !isOffline(err) {
				fmt.Println("La session a expiré, reconnexion…")
			} else {
				return nil, err
			}
		}
	}
	if googleClientID == "" {
		return nil, errors.New("cette version n'a pas de connexion Google configurée")
	}
	fmt.Println("Connexion à ton compte Google : une page va s'ouvrir dans ton navigateur.")
	idToken, err := googleSignIn()
	if err != nil {
		return nil, err
	}
	a, err := firebaseSignIn(idToken)
	if err != nil {
		return nil, err
	}
	a.path = path
	a.save()
	fmt.Printf("Connecté : %s\n\n", a.Email)
	return a, nil
}

func (a *Account) save() {
	os.MkdirAll(filepath.Dir(a.path), 0o700)
	data, _ := json.MarshalIndent(a, "", "  ")
	os.WriteFile(a.path, data, 0o600)
}

// Token: a valid Firebase ID token, refreshed with the stored refresh token.
func (a *Account) Token() (string, error) {
	if a.idToken != "" && time.Now().Before(a.expires) {
		return a.idToken, nil
	}
	form := url.Values{"grant_type": {"refresh_token"}, "refresh_token": {a.RefreshToken}}
	var out struct {
		IDToken      string `json:"id_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    string `json:"expires_in"`
		UserID       string `json:"user_id"`
	}
	if err := postForm("https://securetoken.googleapis.com/v1/token?key="+firebaseAPIKey, form, &out); err != nil {
		return "", err
	}
	a.idToken = out.IDToken
	a.expires = time.Now().Add(50 * time.Minute)
	if out.RefreshToken != "" && out.RefreshToken != a.RefreshToken {
		a.RefreshToken = out.RefreshToken
		a.save()
	}
	return a.idToken, nil
}

// googleSignIn: Google's sign-in for installed apps - the browser, a one-time local
// address for the answer, PKCE. Returns Google's ID token.
func googleSignIn() (string, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	defer listener.Close()
	redirect := fmt.Sprintf("http://127.0.0.1:%d", listener.Addr().(*net.TCPAddr).Port)
	verifier := randomString(48)
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	state := randomString(16)
	auth := "https://accounts.google.com/o/oauth2/v2/auth?" + url.Values{
		"client_id":             {googleClientID},
		"redirect_uri":          {redirect},
		"response_type":         {"code"},
		"scope":                 {"openid email profile"},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"state":                 {state},
		"prompt":                {"select_account"},
	}.Encode()

	codes := make(chan string, 1)
	failures := make(chan error, 1)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if q.Get("state") != state || q.Get("code") == "" {
			fmt.Fprint(w, page("La connexion n'a pas abouti", "Tu peux fermer cet onglet et relancer Capsule."))
			if q.Get("error") != "" {
				failures <- errors.New("connexion refusée (" + q.Get("error") + ")")
			}
			return
		}
		fmt.Fprint(w, page("C'est bon !", "Tu es connecté à Capsule. Tu peux fermer cet onglet et revenir au jeu."))
		codes <- q.Get("code")
	})}
	go server.Serve(listener)
	defer server.Close()

	openBrowser(auth)
	fmt.Println("Si rien ne s'ouvre, copie ce lien dans ton navigateur :")
	fmt.Println(auth)
	fmt.Println()

	var code string
	select {
	case code = <-codes:
	case err := <-failures:
		return "", err
	case <-time.After(5 * time.Minute):
		return "", errors.New("pas de réponse du navigateur après 5 minutes")
	}

	var tok struct {
		IDToken string `json:"id_token"`
	}
	err = postForm("https://oauth2.googleapis.com/token", url.Values{
		"code":          {code},
		"client_id":     {googleClientID},
		"client_secret": {googleClientSecret},
		"redirect_uri":  {redirect},
		"grant_type":    {"authorization_code"},
		"code_verifier": {verifier},
	}, &tok)
	if err != nil {
		return "", err
	}
	if tok.IDToken == "" {
		return "", errors.New("Google n'a pas renvoyé d'identité")
	}
	return tok.IDToken, nil
}

func firebaseSignIn(googleIDToken string) (*Account, error) {
	body := map[string]any{
		"postBody":            "id_token=" + googleIDToken + "&providerId=google.com",
		"requestUri":          "http://localhost",
		"returnSecureToken":   true,
		"returnIdpCredential": true,
	}
	var out struct {
		IDToken      string `json:"idToken"`
		RefreshToken string `json:"refreshToken"`
		LocalID      string `json:"localId"`
		Email        string `json:"email"`
	}
	if err := postJSON("https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key="+firebaseAPIKey, body, &out); err != nil {
		return nil, err
	}
	return &Account{UID: out.LocalID, Email: out.Email, RefreshToken: out.RefreshToken, idToken: out.IDToken,
		expires: time.Now().Add(50 * time.Minute)}, nil
}

func page(title, text string) string {
	return `<!DOCTYPE html><meta charset="utf-8"><title>Capsule</title>
<body style="font-family:system-ui,sans-serif;background:#121216;color:#f1f1f4;display:grid;place-items:center;height:90vh;text-align:center">
<div><h1 style="color:#ff5a5f">` + title + `</h1><p>` + text + `</p></div>`
}

func randomString(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)[:n]
}

func openBrowser(link string) {
	switch runtime.GOOS {
	case "windows":
		exec.Command("rundll32", "url.dll,FileProtocolHandler", link).Start()
	case "darwin":
		exec.Command("open", link).Start()
	default:
		exec.Command("xdg-open", link).Start()
	}
}

// ---- HTTP

var client = &http.Client{Timeout: 60 * time.Second}

type apiError struct {
	status int
	text   string
}

func (e *apiError) Error() string { return fmt.Sprintf("serveur %d : %s", e.status, e.text) }

func isOffline(err error) bool {
	var ae *apiError
	return !errors.As(err, &ae)
}

func do(req *http.Request, out any) error {
	req.Header.Set("Referer", referer)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		var e struct {
			Error any `json:"error"`
		}
		json.NewDecoder(resp.Body).Decode(&e)
		text := fmt.Sprint(e.Error)
		if m, ok := e.Error.(map[string]any); ok {
			text = fmt.Sprint(m["message"])
		}
		return &apiError{resp.StatusCode, strings.TrimSpace(text)}
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func postForm(link string, form url.Values, out any) error {
	req, _ := http.NewRequest("POST", link, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return do(req, out)
}

func postJSON(link string, body any, out any) error {
	data, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", link, strings.NewReader(string(data)))
	req.Header.Set("Content-Type", "application/json")
	return do(req, out)
}
