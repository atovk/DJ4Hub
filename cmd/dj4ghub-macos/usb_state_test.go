package main

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestHealthDoesNotRestoreDisconnectedUSBFromStartupCache(t *testing.T) {
	// An empty inventory represents an unplug without querying real hardware.
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "ioreg"), []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	a := &app{usbDevice: &usbDeviceStatus{Product: "startup device"}}
	w := httptest.NewRecorder()
	a.health(w, httptest.NewRequest("GET", "/api/health", nil))
	var response map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response["usb_device"] != nil {
		t.Fatalf("health restored disconnected USB device: %#v", response["usb_device"])
	}
}

func TestUSBStateConcurrentHealthAndDetachRace(t *testing.T) {
	a := &app{
		demo:           true,
		port:           "USB AT test",
		discoveryError: "initial",
		usbDevice:      &usbDeviceStatus{Product: "DJI 4G Module", Vendor: "DJI"},
	}

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			for j := 0; j < 500; j++ {
				w := httptest.NewRecorder()
				a.health(w, httptest.NewRequest("GET", "/api/health", nil))
			}
		}()
		go func() {
			defer wg.Done()
			for j := 0; j < 500; j++ {
				_ = a.currentUSBDevice()
				a.markUSBATDetached("test detach")
			}
		}()
	}
	wg.Wait()
}

func TestResetUSBATIfGoneIgnoresStaleDeviceError(t *testing.T) {
	oldDev := &usbAT{}
	newDev := &usbAT{}
	a := &app{
		usbAT:          newDev,
		port:           "new session",
		discoveryError: "",
		usbDevice:      &usbDeviceStatus{Product: "DJI 4G Module", Vendor: "DJI"},
	}

	a.resetUSBATIfGoneForDevice(errors.New("NO_DEVICE"), oldDev)

	if got := a.currentUSBAT(); got != newDev {
		t.Fatalf("currentUSBAT() = %p, want new session %p", got, newDev)
	}
	port, discoveryError, usbDevice := a.usbStateSnapshot()
	if port != "new session" || discoveryError != "" || usbDevice == nil {
		t.Fatalf("usb state = port %q discovery %q device %#v, want new session intact", port, discoveryError, usbDevice)
	}
}
