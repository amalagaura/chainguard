package main

import (
	"crypto/x509"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestConfigFromEnvDefaults(t *testing.T) {
	cfg, err := configFromEnv(func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	if cfg.port != "8080" || cfg.httpTimeout != 15*time.Second {
		t.Fatalf("defaults: %+v", cfg)
	}
}

func TestConfigFromEnvRejectsBadPort(t *testing.T) {
	_, err := configFromEnv(func(k string) string {
		if k == "TOKEN_PORT" {
			return "0"
		}
		return ""
	})
	if err == nil {
		t.Fatal("expected port error")
	}
}

func TestParseMintRequest(t *testing.T) {
	req, err := parseMintRequest(strings.NewReader(`{"name":"builder","audience":"sts.amazonaws.com","expiration_seconds":3600}`))
	if err != nil {
		t.Fatal(err)
	}
	if req.Name != "builder" || req.Audience != "sts.amazonaws.com" || req.ExpirationSeconds != 3600 {
		t.Fatalf("%+v", req)
	}
}

func TestParseMintRequestRejectsIncomplete(t *testing.T) {
	for _, body := range []string{
		`{}`,
		`{"name":"builder","audience":"sts.amazonaws.com"}`,
		`{"name":"Builder","audience":"sts.amazonaws.com","expiration_seconds":3600}`,
		`{"name":"../admin","audience":"sts.amazonaws.com","expiration_seconds":3600}`,
		`{"name":"builder","audience":"","expiration_seconds":3600}`,
		`{"name":"builder","audience":"sts.amazonaws.com","expiration_seconds":0}`,
		`{"service_account":"builder"}`,
	} {
		_, err := parseMintRequest(strings.NewReader(body))
		if err == nil {
			t.Fatalf("accepted %s", body)
		}
	}
}

func TestTokenAPIClientDisablesKeepAlives(t *testing.T) {
	parent := &http.Client{Timeout: time.Second}
	pool := x509.NewCertPool()
	client := tokenAPIClient(parent, pool)
	if client == parent {
		t.Fatal("per-call client aliases the shared client")
	}
	if parent.Transport != nil {
		t.Fatal("shared client transport was mutated")
	}
	tr, ok := client.Transport.(*http.Transport)
	if !ok || !tr.DisableKeepAlives {
		t.Fatal("keep-alives still enabled on throwaway transport")
	}
	if tr.TLSClientConfig == nil || tr.TLSClientConfig.RootCAs != pool {
		t.Fatal("CA pool not installed")
	}
}

func TestTokenHandlerBadBody(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/token", strings.NewReader(`{}`))
	rec := httptest.NewRecorder()
	handleToken(rec, req, &http.Client{})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
}
