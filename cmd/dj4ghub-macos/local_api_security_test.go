package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

type localAPITestRequest struct {
	method     string
	target     string
	host       string
	remoteAddr string
	origin     string
	fetchSite  string
	content    string
	audio      bool
	forwarded  string
	body       string
}

func newLocalAPITestRequest(test localAPITestRequest) *http.Request {
	req := httptest.NewRequest(test.method, test.target, strings.NewReader(test.body))
	req.Host = test.host
	req.RemoteAddr = test.remoteAddr
	if test.origin != "" {
		req.Header.Set("Origin", test.origin)
	}
	if test.fetchSite != "" {
		req.Header.Set("Sec-Fetch-Site", test.fetchSite)
	}
	if test.content != "" {
		req.Header.Set("Content-Type", test.content)
	}
	if test.audio {
		req.Header.Set("X-DJ4Hub-Audio", "1")
	}
	if test.forwarded != "" {
		req.Header.Set("X-Forwarded-For", test.forwarded)
	}
	return req
}

func TestLocalAPISecurityRejectsBeforeNext(t *testing.T) {
	tests := []struct {
		name string
		req  localAPITestRequest
		want int
	}{
		{
			name: "evil host dns rebinding",
			req:  localAPITestRequest{method: http.MethodGet, target: "http://evil.example:7575/", host: "evil.example:7575", remoteAddr: "127.0.0.1:53920"},
			want: http.StatusForbidden,
		},
		{
			name: "host with userinfo",
			req:  localAPITestRequest{method: http.MethodGet, target: "http://localhost:7575/", host: "user@localhost:7575", remoteAddr: "127.0.0.1:53920"},
			want: http.StatusForbidden,
		},
		{
			name: "host with path",
			req:  localAPITestRequest{method: http.MethodGet, target: "http://localhost:7575/", host: "localhost:7575/evil", remoteAddr: "127.0.0.1:53920"},
			want: http.StatusForbidden,
		},
		{
			name: "host with query",
			req:  localAPITestRequest{method: http.MethodGet, target: "http://localhost:7575/", host: "localhost:7575?evil=1", remoteAddr: "127.0.0.1:53920"},
			want: http.StatusForbidden,
		},
		{
			name: "host with fragment",
			req:  localAPITestRequest{method: http.MethodGet, target: "http://localhost:7575/", host: "localhost:7575#evil", remoteAddr: "127.0.0.1:53920"},
			want: http.StatusForbidden,
		},
		{
			name: "remote client address",
			req:  localAPITestRequest{method: http.MethodGet, target: "http://localhost:7575/api/status", host: "localhost:7575", remoteAddr: "192.168.1.20:53920"},
			want: http.StatusForbidden,
		},
		{
			name: "foreign origin",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/sms/send", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "https://evil.example", content: "application/json", body: `{"phone":"10086","message":"x"}`},
			want: http.StatusForbidden,
		},
		{
			name: "null origin",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/sms/send", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "null", content: "application/json", body: `{"phone":"10086","message":"x"}`},
			want: http.StatusForbidden,
		},
		{
			name: "foreign origin with custom header",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/calls/audio/stop", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "https://evil.example", audio: true},
			want: http.StatusForbidden,
		},
		{
			name: "wrong origin scheme",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/sms/send", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "https://localhost:7575", content: "application/json", body: `{"phone":"10086","message":"x"}`},
			want: http.StatusForbidden,
		},
		{
			name: "origin with path",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/sms/send", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "http://localhost:7575/evil", content: "application/json", body: `{"phone":"10086","message":"x"}`},
			want: http.StatusForbidden,
		},
		{
			name: "origin with query",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/sms/send", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "http://localhost:7575?evil=1", content: "application/json", body: `{"phone":"10086","message":"x"}`},
			want: http.StatusForbidden,
		},
		{
			name: "origin with fragment",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/sms/send", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "http://localhost:7575#evil", content: "application/json", body: `{"phone":"10086","message":"x"}`},
			want: http.StatusForbidden,
		},
		{
			name: "origin with userinfo",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/sms/send", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "http://user@localhost:7575", content: "application/json", body: `{"phone":"10086","message":"x"}`},
			want: http.StatusForbidden,
		},
		{
			name: "cross site fetch metadata",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/sms/send", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", fetchSite: "cross-site", content: "application/json", body: `{"phone":"10086","message":"x"}`},
			want: http.StatusForbidden,
		},
		{
			name: "simple text plain write",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/calls", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", content: "text/plain", body: `{"action":"dial","number":"10086"}`},
			want: http.StatusUnsupportedMediaType,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int32
			handler := localAPISecurity(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				calls.Add(1)
				w.WriteHeader(http.StatusNoContent)
			}))
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, newLocalAPITestRequest(test.req))

			if w.Code != test.want {
				t.Fatalf("status = %d, want %d, body = %s", w.Code, test.want, w.Body.String())
			}
			if calls.Load() != 0 {
				t.Fatalf("next handler calls = %d, want 0", calls.Load())
			}
		})
	}
}

func TestLocalAPISecurityAllowsTrustedLocalRequests(t *testing.T) {
	tests := []struct {
		name string
		req  localAPITestRequest
	}{
		{
			name: "same origin web",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/sms/send", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "http://localhost:7575", content: "application/json; charset=utf-8", body: `{"phone":"10086","message":"x"}`},
		},
		{
			name: "native no origin",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://127.0.0.1:8765/api/sms/refresh", host: "127.0.0.1:8765", remoteAddr: "127.0.0.1:53920", content: "application/json", body: `{}`},
		},
		{
			name: "local cli json",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:9191/api/at", host: "localhost:9191", remoteAddr: "127.0.0.1:53920", content: "application/json", body: `{"command":"AT"}`},
		},
		{
			name: "ipv6 loopback",
			req:  localAPITestRequest{method: http.MethodGet, target: "http://[::1]:7575/api/health", host: "[::1]:7575", remoteAddr: "[::1]:53920"},
		},
		{
			name: "bodyless audio header",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/calls/audio/stop", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", forwarded: "203.0.113.9", audio: true},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int32
			handler := localAPISecurity(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				calls.Add(1)
				w.WriteHeader(http.StatusNoContent)
			}))
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, newLocalAPITestRequest(test.req))

			if w.Code != http.StatusNoContent {
				t.Fatalf("status = %d, want %d, body = %s", w.Code, http.StatusNoContent, w.Body.String())
			}
			if calls.Load() != 1 {
				t.Fatalf("next handler calls = %d, want 1", calls.Load())
			}
		})
	}
}

func TestRoutesRejectMaliciousWritesBeforeHardwareHandlers(t *testing.T) {
	handler := (&app{demo: true}).routes()
	tests := []struct {
		name string
		req  localAPITestRequest
		want int
	}{
		{
			name: "at text plain",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/at", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", content: "text/plain", body: `{"command":"AT"}`},
			want: http.StatusUnsupportedMediaType,
		},
		{
			name: "calls foreign origin",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://localhost:7575/api/calls", host: "localhost:7575", remoteAddr: "127.0.0.1:53920", origin: "https://evil.example", content: "application/json", body: `{"action":"dial","number":"10086"}`},
			want: http.StatusForbidden,
		},
		{
			name: "reboot remote host",
			req:  localAPITestRequest{method: http.MethodPost, target: "http://evil.example:7575/api/network/reboot-module", host: "evil.example:7575", remoteAddr: "127.0.0.1:53920", content: "application/json", body: `{}`},
			want: http.StatusForbidden,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			w := httptest.NewRecorder()

			handler.ServeHTTP(w, newLocalAPITestRequest(test.req))

			if w.Code != test.want {
				t.Fatalf("status = %d, want %d, body = %s", w.Code, test.want, w.Body.String())
			}
		})
	}
}
