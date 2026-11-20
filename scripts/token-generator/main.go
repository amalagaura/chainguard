package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	saMount         = "/var/run/secrets/kubernetes.io/serviceaccount"
	saTokenPath     = saMount + "/token"
	saCAPath        = saMount + "/ca.crt"
	saNamespacePath = saMount + "/namespace"
	apiHost         = "https://kubernetes.default.svc"

	defaultPort        = "8080"
	defaultHTTPTimeout = 15 * time.Second
	maxBodyBytes       = 4096
)

var serviceAccountNamePattern = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$`)

type serverConfig struct {
	port        string
	httpTimeout time.Duration
}

type mintRequest struct {
	Name              string `json:"name"`
	Audience          string `json:"audience"`
	ExpirationSeconds int64  `json:"expiration_seconds"`
}

func main() {
	cfg, err := configFromEnv(os.Getenv)
	if err != nil {
		log.Fatal(err)
	}

	client := &http.Client{Timeout: cfg.httpTimeout}
	http.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		handleToken(w, r, client)
	})

	log.Printf("token-generator listening on :%s", cfg.port)
	log.Fatal(http.ListenAndServe(":"+cfg.port, nil))
}

func configFromEnv(getenv func(string) string) (serverConfig, error) {
	port := getenv("TOKEN_PORT")
	if port == "" {
		port = defaultPort
	}
	if p, err := strconv.Atoi(port); err != nil || p < 1 || p > 65535 {
		return serverConfig{}, fmt.Errorf("TOKEN_PORT must be an integer from 1 to 65535")
	}

	timeout := defaultHTTPTimeout
	if raw := getenv("TOKEN_HTTP_TIMEOUT_SECONDS"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 {
			return serverConfig{}, fmt.Errorf("TOKEN_HTTP_TIMEOUT_SECONDS must be a positive integer")
		}
		timeout = time.Duration(n) * time.Second
	}

	return serverConfig{port: port, httpTimeout: timeout}, nil
}

func handleToken(w http.ResponseWriter, r *http.Request, client *http.Client) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	req, err := parseMintRequest(r.Body)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusBadRequest)
		return
	}
	token, err := mint(client, req)
	if err != nil {
		log.Printf("mint error: %v", err)
		http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"token":           token,
		"service_account": req.Name,
	})
}

func parseMintRequest(body io.Reader) (mintRequest, error) {
	var req mintRequest
	dec := json.NewDecoder(io.LimitReader(body, maxBodyBytes))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		return mintRequest{}, fmt.Errorf("invalid request body")
	}
	req.Name = strings.TrimSpace(req.Name)
	req.Audience = strings.TrimSpace(req.Audience)
	if !validServiceAccountName(req.Name) {
		return mintRequest{}, fmt.Errorf("name must be a service account name")
	}
	if req.Audience == "" {
		return mintRequest{}, fmt.Errorf("audience is required")
	}
	if req.ExpirationSeconds <= 0 {
		return mintRequest{}, fmt.Errorf("expiration_seconds must be a positive integer")
	}
	return req, nil
}

func validServiceAccountName(name string) bool {
	return len(name) <= 253 && serviceAccountNamePattern.MatchString(name)
}

// tokenAPIClient copies parent so a per-call transport cannot mutate the shared client.
// DisableKeepAlives is required: this transport is discarded after one TokenRequest,
// and the default IdleConnTimeout of 0 would otherwise pin the connection and its goroutines.
func tokenAPIClient(parent *http.Client, pool *x509.CertPool) *http.Client {
	reqClient := *parent
	reqClient.Transport = &http.Transport{
		TLSClientConfig:   &tls.Config{RootCAs: pool},
		DisableKeepAlives: true,
	}
	return &reqClient
}

func mint(client *http.Client, req mintRequest) (string, error) {
	saToken, err := os.ReadFile(saTokenPath)
	if err != nil {
		return "", fmt.Errorf("read SA token: %w", err)
	}
	namespaceBytes, err := os.ReadFile(saNamespacePath)
	if err != nil {
		return "", fmt.Errorf("read namespace: %w", err)
	}
	namespace := strings.TrimSpace(string(namespaceBytes))
	if namespace == "" {
		return "", fmt.Errorf("namespace file is empty")
	}

	caCert, err := os.ReadFile(saCAPath)
	if err != nil {
		return "", fmt.Errorf("read CA: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caCert) {
		return "", fmt.Errorf("failed to parse CA cert")
	}
	reqClient := tokenAPIClient(client, pool)
	// The transport is not reused. Close it after the body so a keep-alive
	// connection cannot outlive this call.
	defer reqClient.CloseIdleConnections()

	body, err := json.Marshal(map[string]any{
		"spec": map[string]any{
			"audiences":         []string{req.Audience},
			"expirationSeconds": req.ExpirationSeconds,
		},
	})
	if err != nil {
		return "", err
	}

	url := fmt.Sprintf("%s/api/v1/namespaces/%s/serviceaccounts/%s/token", apiHost, namespace, req.Name)
	httpReq, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	httpReq.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(saToken)))
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	resp, err := reqClient.Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("TokenRequest failed: %s %s", resp.Status, respBody)
	}

	var result struct {
		Status struct {
			Token string `json:"token"`
		} `json:"status"`
	}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return "", fmt.Errorf("parse response: %w", err)
	}
	if result.Status.Token == "" {
		return "", fmt.Errorf("TokenRequest response missing token")
	}
	return result.Status.Token, nil
}
