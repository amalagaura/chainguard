package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
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

	defaultPort              = "8080"
	defaultAudience          = "sts.amazonaws.com"
	defaultExpirationSeconds = 3600
	defaultHTTPTimeout       = 15 * time.Second
)

type config struct {
	port              string
	audience          string
	expirationSeconds int64
	httpTimeout       time.Duration
}

func main() {
	cfg, err := configFromEnv(os.Getenv)
	if err != nil {
		log.Fatal(err)
	}

	client := &http.Client{Timeout: cfg.httpTimeout}
	http.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		token, sa, err := mint(client, cfg)
		if err != nil {
			log.Printf("mint error: %v", err)
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"token":           token,
			"service_account": sa,
		})
	})

	log.Printf("token-generator listening on :%s audience=%s expiration=%ds", cfg.port, cfg.audience, cfg.expirationSeconds)
	log.Fatal(http.ListenAndServe(":"+cfg.port, nil))
}

func configFromEnv(getenv func(string) string) (config, error) {
	port := getenv("TOKEN_PORT")
	if port == "" {
		port = defaultPort
	}
	if p, err := strconv.Atoi(port); err != nil || p < 1 || p > 65535 {
		return config{}, fmt.Errorf("TOKEN_PORT must be an integer from 1 to 65535")
	}

	audience := getenv("TOKEN_AUDIENCE")
	if audience == "" {
		audience = defaultAudience
	}
	audience = strings.TrimSpace(audience)
	if audience == "" {
		return config{}, fmt.Errorf("TOKEN_AUDIENCE must not be empty")
	}

	expiration := int64(defaultExpirationSeconds)
	if raw := getenv("TOKEN_EXPIRATION_SECONDS"); raw != "" {
		n, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || n <= 0 {
			return config{}, fmt.Errorf("TOKEN_EXPIRATION_SECONDS must be a positive integer")
		}
		expiration = n
	}

	timeout := defaultHTTPTimeout
	if raw := getenv("TOKEN_HTTP_TIMEOUT_SECONDS"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 {
			return config{}, fmt.Errorf("TOKEN_HTTP_TIMEOUT_SECONDS must be a positive integer")
		}
		timeout = time.Duration(n) * time.Second
	}

	return config{
		port:              port,
		audience:          audience,
		expirationSeconds: expiration,
		httpTimeout:       timeout,
	}, nil
}

func mint(client *http.Client, cfg config) (string, string, error) {
	saToken, err := os.ReadFile(saTokenPath)
	if err != nil {
		return "", "", fmt.Errorf("read SA token: %w", err)
	}
	namespaceBytes, err := os.ReadFile(saNamespacePath)
	if err != nil {
		return "", "", fmt.Errorf("read namespace: %w", err)
	}
	namespace := strings.TrimSpace(string(namespaceBytes))
	if namespace == "" {
		return "", "", fmt.Errorf("namespace file is empty")
	}
	saName, err := serviceAccountName(string(saToken))
	if err != nil {
		return "", "", err
	}

	caCert, err := os.ReadFile(saCAPath)
	if err != nil {
		return "", "", fmt.Errorf("read CA: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caCert) {
		return "", "", fmt.Errorf("failed to parse CA cert")
	}
	reqClient := *client
	reqClient.Transport = &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}

	body, err := json.Marshal(map[string]any{
		"spec": map[string]any{
			"audiences":         []string{cfg.audience},
			"expirationSeconds": cfg.expirationSeconds,
		},
	})
	if err != nil {
		return "", "", err
	}

	url := fmt.Sprintf("%s/api/v1/namespaces/%s/serviceaccounts/%s/token", apiHost, namespace, saName)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(saToken)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := reqClient.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("TokenRequest failed: %s %s", resp.Status, respBody)
	}

	var result struct {
		Status struct {
			Token string `json:"token"`
		} `json:"status"`
	}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return "", "", fmt.Errorf("parse response: %w", err)
	}
	if result.Status.Token == "" {
		return "", "", fmt.Errorf("TokenRequest response missing token")
	}
	return result.Status.Token, saName, nil
}

func serviceAccountName(token string) (string, error) {
	payload, err := jwtPayload(token)
	if err != nil {
		return "", err
	}
	var claims struct {
		Sub        string `json:"sub"`
		Kubernetes struct {
			ServiceAccount struct {
				Name string `json:"name"`
			} `json:"serviceaccount"`
		} `json:"kubernetes.io"`
		LegacyName string `json:"kubernetes.io/serviceaccount/service-account.name"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return "", fmt.Errorf("parse projected token: %w", err)
	}
	if name := claims.Kubernetes.ServiceAccount.Name; name != "" {
		return name, nil
	}
	if claims.LegacyName != "" {
		return claims.LegacyName, nil
	}
	const prefix = "system:serviceaccount:"
	if rest, ok := strings.CutPrefix(claims.Sub, prefix); ok {
		_, name, found := strings.Cut(rest, ":")
		if found && name != "" {
			return name, nil
		}
	}
	return "", fmt.Errorf("projected token has no service account name")
}

func jwtPayload(token string) ([]byte, error) {
	parts := strings.Split(strings.TrimSpace(token), ".")
	if len(parts) < 2 || parts[1] == "" {
		return nil, fmt.Errorf("projected token is not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		payload, err = base64.URLEncoding.DecodeString(parts[1])
	}
	if err != nil {
		return nil, fmt.Errorf("decode projected token: %w", err)
	}
	return payload, nil
}
