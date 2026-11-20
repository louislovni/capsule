package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The saves on the account, as the iPhone app keeps them (CloudSync.swift): users/UID/files/ID describes a
// file (name, SHA-256, size, pieces, version), users/UID/chunks/ID_VERSION_N holds its bytes in base64 pieces.
// The hash each file had at the last sync (saves/.cloud.json) says which side changed since: one side only,
// it goes to the other; both, the newer stays and the other is kept in backups/cloud.

const chunkSize = 600_000
const bankName = "#banque"

type doc struct {
	id     string
	fields map[string]map[string]any
}

func (d doc) str(key string) string {
	if v, ok := d.fields[key]["stringValue"].(string); ok {
		return v
	}
	return ""
}

func (d doc) int(key string) int {
	switch v := d.fields[key]["integerValue"].(type) {
	case string:
		n, _ := strconv.Atoi(v)
		return n
	case float64:
		return int(v)
	}
	return 0
}

func (d doc) time(key string) time.Time {
	if v, ok := d.fields[key]["timestampValue"].(string); ok {
		t, _ := time.Parse(time.RFC3339Nano, v)
		return t
	}
	return time.Time{}
}

type store struct {
	account *Account
	root    string
}

// firestoreHost: tests point it at a fake (cloud_test.go).
var firestoreHost = "https://firestore.googleapis.com"

func (s store) url(path string) string {
	return firestoreHost + "/v1/projects/" + projectID + "/databases/(default)/documents/" + s.root + "/" + path
}

func (s store) request(method, path string, body any, out any) error {
	token, err := s.account.Token()
	if err != nil {
		return err
	}
	var req *http.Request
	if body != nil {
		data, _ := json.Marshal(body)
		req, _ = http.NewRequest(method, s.url(path), strings.NewReader(string(data)))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req, _ = http.NewRequest(method, s.url(path), nil)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	return do(req, out)
}

type rawDoc struct {
	Name   string                    `json:"name"`
	Fields map[string]map[string]any `json:"fields"`
}

func toDoc(r rawDoc) doc { return doc{id: r.Name[strings.LastIndex(r.Name, "/")+1:], fields: r.Fields} }

func (s store) list(collection string) ([]doc, error) {
	var docs []doc
	token := ""
	for {
		path := collection + "?pageSize=300"
		if token != "" {
			path += "&pageToken=" + token
		}
		var out struct {
			Documents     []rawDoc `json:"documents"`
			NextPageToken string   `json:"nextPageToken"`
		}
		if err := s.request("GET", path, nil, &out); err != nil {
			return nil, err
		}
		for _, r := range out.Documents {
			docs = append(docs, toDoc(r))
		}
		if out.NextPageToken == "" {
			return docs, nil
		}
		token = out.NextPageToken
	}
}

func (s store) get(path string) (*doc, error) {
	var out rawDoc
	err := s.request("GET", path, nil, &out)
	var ae *apiError
	if errors.As(err, &ae) && ae.status == 404 {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	d := toDoc(out)
	return &d, nil
}

func (s store) set(path string, fields map[string]any) error {
	return s.request("PATCH", path, map[string]any{"fields": fields}, nil)
}

func (s store) delete(path string) error { return s.request("DELETE", path, nil, nil) }

func hashOf(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func fileID(name string) string { return hashOf([]byte(name))[:32] }

// coreHash: the save's hash without mGBA's 16-byte clock footer (every save chip is a multiple of 512 bytes, the
// footer is what's past the last whole 512). The footer moves with the clock alone, and PC's libretro core writes
// none: two saves with the same core are the same save, whatever their clocks say.
func coreHash(data []byte) string {
	n := len(data) - len(data)%512
	if n == 0 {
		return hashOf(data)
	}
	return hashOf(data[:n])
}

// upload: [modified] is when the save was written on this device (conflicts go by it, not by the upload's time).
func (s store) upload(name string, data []byte, hash string, modified time.Time) error {
	id := fileID(name)
	text := base64.StdEncoding.EncodeToString(data)
	var pieces []string
	for start := 0; start < len(text); start += chunkSize {
		end := start + chunkSize
		if end > len(text) {
			end = len(text)
		}
		pieces = append(pieces, text[start:end])
	}
	if len(pieces) == 0 {
		pieces = []string{""}
	}
	version := hash[:12]
	for i, piece := range pieces {
		if err := s.set(fmt.Sprintf("chunks/%s_%s_%d", id, version, i), map[string]any{"data": map[string]any{"stringValue": piece}}); err != nil {
			return err
		}
	}
	old, err := s.get("files/" + id)
	if err != nil {
		return err
	}
	host, _ := os.Hostname()
	err = s.set("files/"+id, map[string]any{
		"name":       map[string]any{"stringValue": name},
		"hash":       map[string]any{"stringValue": hash},
		"core":       map[string]any{"stringValue": coreHash(data)},
		"modifiedAt": map[string]any{"timestampValue": modified.UTC().Format(time.RFC3339Nano)},
		"size":       map[string]any{"integerValue": strconv.Itoa(len(data))},
		"chunks":     map[string]any{"integerValue": strconv.Itoa(len(pieces))},
		"version":    map[string]any{"stringValue": version},
		"updatedAt":  map[string]any{"timestampValue": time.Now().UTC().Format(time.RFC3339Nano)},
		"device":     map[string]any{"stringValue": "PC " + host},
	})
	if err != nil {
		return err
	}
	if old != nil && old.str("version") != "" && old.str("version") != version {
		for i := 0; i < old.int("chunks"); i++ {
			s.delete(fmt.Sprintf("chunks/%s_%s_%d", id, old.str("version"), i))
		}
	}
	return nil
}

func (s store) download(d doc) ([]byte, error) {
	version, hash, count := d.str("version"), d.str("hash"), d.int("chunks")
	if version == "" || hash == "" {
		return nil, errors.New("fichier incomplet dans le cloud")
	}
	var text strings.Builder
	for i := 0; i < count; i++ {
		piece, err := s.get(fmt.Sprintf("chunks/%s_%s_%d", d.id, version, i))
		if err != nil {
			return nil, err
		}
		if piece == nil {
			return nil, errors.New("morceau manquant dans le cloud")
		}
		text.WriteString(piece.str("data"))
	}
	data, err := base64.StdEncoding.DecodeString(text.String())
	if err != nil || hashOf(data) != hash {
		return nil, errors.New("fichier abîmé dans le cloud")
	}
	return data, nil
}

// ---- The sync

func modTime(dir, name string) time.Time {
	if info, err := os.Stat(filepath.Join(dir, "saves", name)); err == nil {
		return info.ModTime()
	}
	return time.Now()
}

func localSaves(dir string) map[string][]byte {
	saves := map[string][]byte{}
	entries, _ := os.ReadDir(filepath.Join(dir, "saves"))
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || strings.HasPrefix(name, ".") || !strings.EqualFold(filepath.Ext(name), ".sav") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, "saves", name))
		if err == nil && len(data) > 0 && len(data) < 4_000_000 {
			saves[name] = data
		}
	}
	return saves
}

func loadManifest(path string) map[string]string {
	m := map[string]string{}
	if data, err := os.ReadFile(path); err == nil {
		json.Unmarshal(data, &m)
	}
	return m
}

func backup(dir, name, tag string, data []byte) error {
	folder := filepath.Join(dir, "backups", "cloud")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return err
	}
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	return os.WriteFile(filepath.Join(folder, fmt.Sprintf("%s-%s-%s%s", base, tag, time.Now().Format("2006-01-02-150405"), ext)), data, 0o644)
}

func writeSave(dir, name string, data []byte, keepOld bool) error {
	path := filepath.Join(dir, "saves", name)
	if keepOld {
		if old, err := os.ReadFile(path); err == nil {
			if err := backup(dir, name, "avant-cloud", old); err != nil {
				return err
			}
		}
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func syncSaves(dir string, account *Account) (string, error) {
	s := store{account: account, root: "users/" + account.UID}
	docs, err := s.list("files")
	if err != nil {
		return "", err
	}
	cloud := map[string]doc{}
	for _, d := range docs {
		if name := d.str("name"); name != "" && name != bankName {
			cloud[name] = d
		}
	}
	manifestPath := filepath.Join(dir, "saves", ".cloud.json")
	manifest := loadManifest(manifestPath)
	local := localSaves(dir)

	names := map[string]bool{}
	for n := range local {
		names[n] = true
	}
	for n := range cloud {
		names[n] = true
	}
	sorted := make([]string, 0, len(names))
	for n := range names {
		sorted = append(sorted, n)
	}
	sort.Strings(sorted)

	sent, received, conflicts := 0, 0, 0
	var firstErr error
	for _, name := range sorted {
		data, haveLocal := local[name]
		d, haveCloud := cloud[name]
		localHash, cloudHash := "", ""
		if haveLocal {
			localHash = hashOf(data)
		}
		if haveCloud {
			cloudHash = d.str("hash")
		}
		synced, syncedCore := manifest[name], manifest["core:"+name]
		localCore, cloudCore := "", ""
		if haveLocal {
			localCore = coreHash(data)
		}
		if haveCloud {
			cloudCore = d.str("core")
		}
		if localHash == cloudHash || (localCore != "" && localCore == cloudCore) {
			// The same save (maybe with another clock footer): nothing to send.
			if haveLocal {
				manifest[name], manifest["core:"+name] = localHash, localCore
			}
			continue
		}
		// Changed since the last sync: by the save's core when the last sync noted it, else by the whole file.
		localChanged := localHash != "" && localHash != synced
		if localChanged && syncedCore != "" {
			localChanged = localCore != syncedCore
		}
		cloudChanged := cloudHash != "" && cloudHash != synced
		if cloudChanged && syncedCore != "" && cloudCore != "" {
			cloudChanged = cloudCore != syncedCore
		}
		var err error
		switch {
		case haveLocal && (cloudHash == "" || (localChanged && !cloudChanged)):
			if err = s.upload(name, data, localHash, modTime(dir, name)); err == nil {
				manifest[name], manifest["core:"+name] = localHash, localCore
				sent++
				fmt.Println("  ↑", strings.TrimSuffix(name, ".sav"))
			}
		case haveCloud && (!haveLocal || (cloudChanged && !localChanged)):
			var theirs []byte
			if theirs, err = s.download(d); err == nil {
				if err = writeSave(dir, name, theirs, haveLocal); err == nil {
					manifest[name], manifest["core:"+name] = cloudHash, coreHash(theirs)
					received++
					fmt.Println("  ↓", strings.TrimSuffix(name, ".sav"))
				}
			}
		case haveLocal && haveCloud:
			// Changed on both sides: the save made last goes on (when each was written, not uploaded), the other is kept.
			localDate := modTime(dir, name)
			var theirs []byte
			if theirs, err = s.download(d); err == nil {
				cloudDate := d.time("modifiedAt")
				if cloudDate.IsZero() {
					cloudDate = d.time("updatedAt") // uploaded before modifiedAt existed
				}
				if !localDate.Before(cloudDate) {
					if err = backup(dir, name, "cloud", theirs); err == nil {
						if err = s.upload(name, data, localHash, modTime(dir, name)); err == nil {
							manifest[name], manifest["core:"+name] = localHash, localCore
						}
					}
				} else if err = writeSave(dir, name, theirs, true); err == nil {
					manifest[name], manifest["core:"+name] = cloudHash, coreHash(theirs)
				}
				if err == nil {
					conflicts++
					fmt.Println("  ⇅", strings.TrimSuffix(name, ".sav"), "(modifiée des deux côtés : la plus récente gardée, l'autre dans backups)")
				}
			}
		}
		if err != nil && firstErr == nil {
			firstErr = fmt.Errorf("%s : %w", name, err)
		}
	}
	if data, err := json.Marshal(manifest); err == nil {
		os.WriteFile(manifestPath, data, 0o644)
	}
	if firstErr != nil {
		return "", firstErr
	}
	if sent+received+conflicts == 0 {
		return "Tout est déjà à jour.", nil
	}
	parts := []string{}
	if received > 0 {
		parts = append(parts, plural(received, "reçue", "reçues"))
	}
	if sent > 0 {
		parts = append(parts, plural(sent, "envoyée", "envoyées"))
	}
	if conflicts > 0 {
		parts = append(parts, plural(conflicts, "conflit réglé", "conflits réglés"))
	}
	return "Sauvegardes : " + strings.Join(parts, ", ") + ".", nil
}
