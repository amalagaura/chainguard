package main

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func TestConfigFromEnvDefaults(t *testing.T) {
	cfg, err := configFromEnv(func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	if cfg.port != "8080" || cfg.audience != "sts.amazonaws.com" || cfg.expirationSeconds != 3600 || cfg.httpTimeout != 15*time.Second {
		t.Fatalf("defaults: %+v", cfg)
	}
}

func TestConfigFromEnvRejectsBadNumbers(t *testing.T) {
	_, err := configFromEnv(func(k string) string {
		if k == "TOKEN_EXPIRATION_SECONDS" {
			return "0"
		}
		return ""
	})
	if err == nil {
		t.Fatal("expected expiration error")
	}
}

func TestServiceAccountName(t *testing.T) {
	bound := jwt(t, `{"sub":"system:serviceaccount:default:pod-sa","kubernetes.io":{"serviceaccount":{"name":"pod-sa"}}}`)
	name, err := serviceAccountName(bound)
	if err != nil || name != "pod-sa" {
		t.Fatalf("bound: %q %v", name, err)
	}

	legacy := jwt(t, `{"kubernetes.io/serviceaccount/service-account.name":"legacy-sa"}`)
	name, err = serviceAccountName(legacy)
	if err != nil || name != "legacy-sa" {
		t.Fatalf("legacy: %q %v", name, err)
	}

	subject := jwt(t, `{"sub":"system:serviceaccount:ns:from-sub"}`)
	name, err = serviceAccountName(subject)
	if err != nil || name != "from-sub" {
		t.Fatalf("sub: %q %v", name, err)
	}
}

func jwt(t *testing.T, payload string) string {
	t.Helper()
	return "e30." + base64.RawURLEncoding.EncodeToString([]byte(payload)) + ".sig"
}

func TestServiceAccountNameRejectsGarbage(t *testing.T) {
	_, err := serviceAccountName("not-a-jwt")
	if err == nil || !strings.Contains(err.Error(), "JWT") {
		t.Fatal(err)
	}
}
