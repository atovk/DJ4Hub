package main

import (
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
)

func localAPISecurity(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !localAPIRequestIsLoopback(r) {
			writeError(w, http.StatusForbidden, "local API only accepts loopback requests")
			return
		}
		if !localAPIOriginAllowed(r) {
			writeError(w, http.StatusForbidden, "local API only accepts same-origin requests")
			return
		}
		if !localAPIWriteAllowed(r) {
			writeError(w, http.StatusUnsupportedMediaType, "local API writes require application/json")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func localAPIRequestIsLoopback(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || !net.ParseIP(host).IsLoopback() {
		return false
	}
	hostURL, err := url.Parse("http://" + r.Host)
	if err != nil || hostURL.User != nil || hostURL.RawQuery != "" || hostURL.Fragment != "" || hostURL.Path != "" {
		return false
	}
	host = hostURL.Hostname()
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func localAPIOriginAllowed(r *http.Request) bool {
	if strings.EqualFold(r.Header.Get("Sec-Fetch-Site"), "cross-site") {
		return false
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	if err != nil || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" {
		return false
	}
	if u.Scheme != localAPIRequestScheme(r) {
		return false
	}
	return u.Host == r.Host
}

func localAPIRequestScheme(r *http.Request) string {
	if r.TLS != nil {
		return "https"
	}
	return "http"
}

func localAPIWriteAllowed(r *http.Request) bool {
	switch r.Method {
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
	default:
		return true
	}
	if r.Header.Get("X-DJ4Hub-Audio") == "1" {
		return true
	}
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	return err == nil && mediaType == "application/json"
}
