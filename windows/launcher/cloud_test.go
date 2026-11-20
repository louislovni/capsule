package main

// syncSaves against a fake Firestore (the REST calls cloud.go makes: list, get, PATCH, DELETE), with two or three
// "devices" (data folders) on one account: what goes up, what comes down, what's a conflict.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeFirestore struct {
	mu   sync.Mutex
	docs map[string]map[string]any // full document path -> fields
}

func (f *fakeFirestore) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	path := strings.TrimPrefix(r.URL.Path, "/v1/")
	switch r.Method {
	case "GET":
		if fields, ok := f.docs[path]; ok {
			json.NewEncoder(w).Encode(map[string]any{"name": path, "fields": fields})
			return
		}
		// A collection: its direct documents.
		var list []map[string]any
		var keys []string
		for k := range f.docs {
			if strings.HasPrefix(k, path+"/") && !strings.Contains(k[len(path)+1:], "/") {
				keys = append(keys, k)
			}
		}
		sort.Strings(keys)
		for _, k := range keys {
			list = append(list, map[string]any{"name": k, "fields": f.docs[k]})
		}
		if len(list) == 0 && !strings.HasSuffix(path, "files") {
			w.WriteHeader(404)
			w.Write([]byte(`{"error":{"message":"not found"}}`))
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"documents": list})
	case "PATCH":
		var body struct {
			Fields map[string]any `json:"fields"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		f.docs[path] = body.Fields
		w.Write([]byte("{}"))
	case "DELETE":
		delete(f.docs, path)
		w.Write([]byte("{}"))
	}
}

func (f *fakeFirestore) chunks() int {
	n := 0
	for k := range f.docs {
		if strings.Contains(k, "/chunks/") {
			n++
		}
	}
	return n
}

type device struct {
	t   *testing.T
	dir string
	acc *Account
}

func newDevice(t *testing.T) device {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "saves"), 0o755)
	return device{t, dir, &Account{UID: "u1", idToken: "token", expires: time.Now().Add(time.Hour)}}
}

func (d device) write(name string, data []byte, mod time.Time) {
	p := filepath.Join(d.dir, "saves", name)
	if err := os.WriteFile(p, data, 0o644); err != nil {
		d.t.Fatal(err)
	}
	os.Chtimes(p, mod, mod)
}

func (d device) read(name string) []byte {
	data, _ := os.ReadFile(filepath.Join(d.dir, "saves", name))
	return data
}

func (d device) sync() string {
	report, err := syncSaves(d.dir, d.acc)
	if err != nil {
		d.t.Fatal(err)
	}
	return report
}

func (d device) backups() int {
	entries, _ := os.ReadDir(filepath.Join(d.dir, "backups", "cloud"))
	return len(entries)
}

// A 128 KB save (Emerald's flash) and the same with mGBA's 16-byte clock footer.
func save(fill byte) []byte { return bytes.Repeat([]byte{fill}, 128<<10) }
func withClock(data []byte, clock byte) []byte {
	return append(append([]byte{}, data...), bytes.Repeat([]byte{clock}, 16)...)
}

func TestSyncBetweenDevices(t *testing.T) {
	fake := &fakeFirestore{docs: map[string]map[string]any{}}
	server := httptest.NewServer(fake)
	defer server.Close()
	firestoreHost = server.URL

	iphone, pc, android := newDevice(t), newDevice(t), newDevice(t)
	t0 := time.Now().Add(-time.Hour)

	// The iPhone's save (with a clock footer) goes up; the PC gets it.
	iphone.write("Emerald.sav", withClock(save(1), 7), t0)
	if r := iphone.sync(); !strings.Contains(r, "1 envoyée") {
		t.Fatalf("iphone first sync: %s", r)
	}
	if r := pc.sync(); !strings.Contains(r, "1 reçue") || !bytes.Equal(pc.read("Emerald.sav"), withClock(save(1), 7)) {
		t.Fatalf("pc first sync: %s", r)
	}

	// The PC's core writes the same save back without the footer: nothing to send (the same save).
	pc.write("Emerald.sav", save(1), t0.Add(time.Minute))
	if r := pc.sync(); r != "Tout est déjà à jour." {
		t.Fatalf("footer-less copy was sent: %s", r)
	}

	// The iPhone's clock moves (footer only), the PC saves for real: the PC's progress reaches the iPhone, no conflict.
	iphone.write("Emerald.sav", withClock(save(1), 9), t0.Add(2*time.Minute))
	pc.write("Emerald.sav", save(2), t0.Add(3*time.Minute))
	if r := pc.sync(); !strings.Contains(r, "1 envoyée") {
		t.Fatalf("pc progress: %s", r)
	}
	if r := iphone.sync(); !strings.Contains(r, "1 reçue") || strings.Contains(r, "conflit") {
		t.Fatalf("iphone after pc progress: %s", r)
	}
	if !bytes.Equal(iphone.read("Emerald.sav"), save(2)) {
		t.Fatal("iphone didn't get the pc's progress")
	}

	// Both save for real while apart: the newer stays everywhere, the other is kept in backups.
	android.sync()
	iphone.write("Emerald.sav", withClock(save(3), 1), time.Now().Add(-10*time.Minute))
	android.write("Emerald.sav", save(4), time.Now().Add(-5*time.Minute))
	iphone.sync()
	if r := android.sync(); !strings.Contains(r, "conflit") {
		t.Fatalf("no conflict: %s", r)
	}
	if !bytes.Equal(android.read("Emerald.sav"), save(4)) || android.backups() == 0 {
		t.Fatal("the newer save didn't win, or the other wasn't kept")
	}
	if r := iphone.sync(); !strings.Contains(r, "1 reçue") || !bytes.Equal(iphone.read("Emerald.sav"), save(4)) {
		t.Fatalf("iphone after the conflict: %s", r)
	}

	// Old versions' pieces are deleted: one file, one piece.
	if n := fake.chunks(); n != 1 {
		t.Fatalf("%d pieces left in the cloud", n)
	}

	// A file uploaded before "core" existed (no core field) still syncs by its whole hash.
	for k, fields := range fake.docs {
		if strings.Contains(k, "/files/") {
			delete(fields, "core")
		}
	}
	if r := pc.sync(); !strings.Contains(r, "1 reçue") || !bytes.Equal(pc.read("Emerald.sav"), save(4)) {
		t.Fatalf("old cloud file: %s", r)
	}
}
