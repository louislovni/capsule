package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
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
// [file] is the save's file name here (the cloud file's "file": a device without the game names it so).
func (s store) upload(name, file string, data []byte, hash string, modified time.Time) error {
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
		"file":       map[string]any{"stringValue": file},
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
		// The version replaced goes into the game's cloud history (its pieces kept), for every device's SAVE
		// HISTORY ([syncHistory]); one that can't be kept is deleted as before.
		entry := map[string]any{"fileId": map[string]any{"stringValue": id}}
		for k, v := range old.fields {
			if k != "fileId" {
				entry[k] = v
			}
		}
		if s.set("history/"+id+"_"+old.str("version"), entry) != nil {
			for i := 0; i < old.int("chunks"); i++ {
				s.delete(fmt.Sprintf("chunks/%s_%s_%d", id, old.str("version"), i))
			}
		}
	}
	return nil
}

// historyKeep: the versions a game's cloud history keeps (as each device's own SAVE HISTORY: 20).
const historyKeep = 20

// syncHistory: the cloud's history for the games here (older versions of their saves, from any device) comes down
// into the local backups SAVE HISTORY lists (DATA/saves/pokedaisy-backups, named by when each was saved), each once;
// one already here (the same core as a local backup or the save) is skipped. Past [historyKeep] a game's oldest go.
func syncHistory(s store, dir string, fileOf map[string]string, manifest map[string]string) {
	entries, err := s.list("history")
	if err != nil {
		return
	}
	byKey := map[string][]doc{}
	for _, d := range entries {
		byKey[d.str("name")] = append(byKey[d.str("name")], d)
	}
	backups := filepath.Join(dir, "saves", "pokedaisy-backups")
	for key, list := range byKey {
		sort.Slice(list, func(i, j int) bool { return list[i].time("modifiedAt").After(list[j].time("modifiedAt")) })
		for _, d := range list[min(len(list), historyKeep):] {
			for i := 0; i < d.int("chunks"); i++ {
				s.delete(fmt.Sprintf("chunks/%s_%s_%d", d.str("fileId"), d.str("version"), i))
			}
			s.delete("history/" + d.id)
		}
		file := fileOf[key]
		if file == "" {
			continue
		}
		stem := strings.TrimSuffix(file, filepath.Ext(file))
		var have map[string]bool // the cores here: read once a game has something new to look at
		for _, d := range list[:min(len(list), historyKeep)] {
			if manifest["history:"+d.id] != "" {
				continue
			}
			if have == nil {
				have = map[string]bool{}
				if data, err := os.ReadFile(filepath.Join(dir, "saves", file)); err == nil {
					have[coreHash(data)] = true
				}
				matches, _ := filepath.Glob(filepath.Join(backups, stem+".backup-*"))
				for _, m := range matches {
					if data, err := os.ReadFile(m); err == nil {
						have[coreHash(data)] = true
					}
				}
			}
			if have[d.str("core")] {
				manifest["history:"+d.id] = "1"
				continue
			}
			data, err := s.download(doc{id: d.str("fileId"), fields: d.fields})
			if err != nil {
				continue
			}
			when := d.time("modifiedAt")
			if when.IsZero() {
				when = d.time("updatedAt")
			}
			os.MkdirAll(backups, 0o755)
			path := filepath.Join(backups, stem+".backup-"+when.Local().Format("20060102-150405")+".sav")
			if _, err := os.Stat(path); err != nil {
				if os.WriteFile(path, data, 0o644) != nil {
					continue
				}
				os.Chtimes(path, when, when)
			}
			have[coreHash(data)] = true
			manifest["history:"+d.id] = "1"
		}
	}
}

// remove deletes a cloud file and its pieces (an old name-keyed copy, once moved to its game's key).
func (s store) remove(d doc) {
	for i := 0; i < d.int("chunks"); i++ {
		s.delete(fmt.Sprintf("chunks/%s_%s_%d", d.id, d.str("version"), i))
	}
	s.delete("files/" + d.id)
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

// A save's cloud name is its game's: "rom:" + the ROM's CRC32, the same on every device that has that ROM whatever
// its file is called (the iPhone's CloudSync.swift and Android's CapsuleCloud.kt do the same). A save without its ROM
// here keeps its file name, unless a game's cloud file says it's that game's ("file").

var romExts = map[string]bool{".gba": true, ".gb": true, ".gbc": true, ".nds": true}

// romKeys: the save file name -> its game's key, for the ROMs in DATA/roms (each CRC32 kept in
// DATA/capsule/crc.json by size and date, so a ROM is read once).
func romKeys(dir string) map[string]string {
	cachePath := filepath.Join(dir, "capsule", "crc.json")
	cache := loadManifest(cachePath)
	keys := map[string]string{}
	taken := map[string]bool{}
	entries, _ := os.ReadDir(filepath.Join(dir, "roms"))
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	changed := false
	for _, e := range entries {
		ext := strings.ToLower(filepath.Ext(e.Name()))
		info, err := e.Info()
		if e.IsDir() || !romExts[ext] || err != nil {
			continue
		}
		stamp := fmt.Sprintf("%s|%d|%d", e.Name(), info.Size(), info.ModTime().Unix())
		crc := cache[stamp]
		if crc == "" {
			data, err := os.ReadFile(filepath.Join(dir, "roms", e.Name()))
			if err != nil {
				continue
			}
			crc = fmt.Sprintf("%08X", crc32.ChecksumIEEE(data))
			cache[stamp] = crc
			changed = true
		}
		key := "rom:" + crc
		if taken[key] { // the same ROM twice: the first file's save is the game's
			continue
		}
		taken[key] = true
		keys[strings.TrimSuffix(e.Name(), filepath.Ext(e.Name()))+".sav"] = key
	}
	if changed {
		os.MkdirAll(filepath.Dir(cachePath), 0o755)
		if data, err := json.Marshal(cache); err == nil {
			os.WriteFile(cachePath, data, 0o644)
		}
	}
	return keys
}

func newer(a, b doc) bool { return a.time("updatedAt").After(b.time("updatedAt")) }

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
	return syncSavesWith(dir, account, false)
}

// pushSaves: while a game runs, the saves changed here go up, and nothing else happens (no download over a save
// in use, no conflict settled: the sync after the game does that).
func pushSaves(dir string, account *Account) error {
	_, err := syncSavesWith(dir, account, true)
	return err
}

// watchSaves: while [done] is open, every [every] the saves folder is looked at; a save written since and left
// alone for [settle] (the game finished writing it) goes up with [pushSaves]. A failure (offline) waits for the next.
func watchSaves(dir string, account *Account, every, settle time.Duration, done <-chan struct{}) {
	stamp := func() map[string]time.Time {
		m := map[string]time.Time{}
		entries, _ := os.ReadDir(filepath.Join(dir, "saves"))
		for _, e := range entries {
			if info, err := e.Info(); err == nil && strings.EqualFold(filepath.Ext(e.Name()), ".sav") {
				m[e.Name()] = info.ModTime()
			}
		}
		return m
	}
	sent := stamp()
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
		}
		now := stamp()
		pending := false
		for name, t := range now {
			if !t.Equal(sent[name]) && time.Since(t) >= settle {
				pending = true
			}
		}
		if !pending {
			continue
		}
		if err := pushSaves(dir, account); err == nil {
			sent = now
		}
	}
}

func syncSavesWith(dir string, account *Account, pushOnly bool) (string, error) {
	s := store{account: account, root: "users/" + account.UID}
	docs, err := s.list("files")
	if err != nil {
		return "", err
	}
	manifestPath := filepath.Join(dir, "saves", ".cloud.json")
	manifest := loadManifest(manifestPath)
	byFile := romKeys(dir) // a local save's file name -> its game's key

	// The cloud's files by key; a game's file also by the save file name it was uploaded with ("file").
	cloud := map[string]doc{}
	gameOfFile := map[string]string{}
	var legacy []doc
	for _, d := range docs {
		name := d.str("name")
		switch {
		case name == "" || name == bankName:
		case strings.HasPrefix(name, "rom:"):
			if prev, ok := cloud[name]; !ok || newer(d, prev) {
				cloud[name] = d
			}
			if f := d.str("file"); f != "" {
				gameOfFile[f] = name
			}
		default:
			legacy = append(legacy, d)
		}
	}
	// Local saves by key: their game's, else a game's that a cloud file names them by, else their file name.
	local := map[string][]byte{}
	fileOf := map[string]string{}
	for file, data := range localSaves(dir) {
		key := byFile[file]
		if key == "" {
			key = gameOfFile[file]
		}
		if key == "" {
			key = file
		}
		local[key], fileOf[key] = data, file
	}
	// A save uploaded by its file name (before game keys, or from a device without the game): its game's file
	// when it's a local game's save (the newer of the two if both exist; the old one goes once synced).
	moved := map[string]doc{}
	for _, d := range legacy {
		name := d.str("name")
		key := byFile[name]
		if key == "" {
			key = gameOfFile[name]
		}
		if key == "" {
			cloud[name] = d
			continue
		}
		if cur, ok := cloud[key]; !ok || newer(d, cur) {
			cloud[key] = d
		}
		moved[key] = d
		if fileOf[key] == "" {
			fileOf[key] = name
		}
		if manifest[key] == "" && manifest[name] != "" { // the last sync's by its old name
			manifest[key], manifest["core:"+key] = manifest[name], manifest["core:"+name]
		}
	}
	for file, key := range byFile { // a game here with no save yet: its save's name here
		if fileOf[key] == "" {
			fileOf[key] = file
		}
	}
	for key, d := range cloud {
		if fileOf[key] == "" {
			if f := d.str("file"); f != "" {
				fileOf[key] = f
			} else {
				fileOf[key] = key
			}
		}
	}

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
		file := fileOf[name]
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
		var err error
		if localHash == cloudHash || (localCore != "" && localCore == cloudCore) {
			// The same save (maybe with another clock footer): nothing to send.
			if haveLocal {
				manifest[name], manifest["core:"+name] = localHash, localCore
			}
		} else {
			// Changed since the last sync: by the save's core when the last sync noted it, else by the whole file.
			localChanged := localHash != "" && localHash != synced
			if localChanged && syncedCore != "" {
				localChanged = localCore != syncedCore
			}
			cloudChanged := cloudHash != "" && cloudHash != synced
			if cloudChanged && syncedCore != "" && cloudCore != "" {
				cloudChanged = cloudCore != syncedCore
			}
			switch {
			case pushOnly && !(haveLocal && (cloudHash == "" || (localChanged && !cloudChanged))):
				// Only a save changed here alone goes up while playing.
			case haveLocal && (cloudHash == "" || (localChanged && !cloudChanged)):
				if err = s.upload(name, file, data, localHash, modTime(dir, file)); err == nil {
					manifest[name], manifest["core:"+name] = localHash, localCore
					sent++
					fmt.Println("  ↑", strings.TrimSuffix(file, ".sav"))
				}
			case haveCloud && (!haveLocal || (cloudChanged && !localChanged)):
				var theirs []byte
				if theirs, err = s.download(d); err == nil {
					if err = writeSave(dir, file, theirs, haveLocal); err == nil {
						manifest[name], manifest["core:"+name] = cloudHash, coreHash(theirs)
						received++
						fmt.Println("  ↓", strings.TrimSuffix(file, ".sav"))
					}
				}
			case haveLocal && haveCloud:
				// Changed on both sides: the save made last goes on (when each was written, not uploaded), the other is kept.
				localDate := modTime(dir, file)
				var theirs []byte
				if theirs, err = s.download(d); err == nil {
					cloudDate := d.time("modifiedAt")
					if cloudDate.IsZero() {
						cloudDate = d.time("updatedAt") // uploaded before modifiedAt existed
					}
					if !localDate.Before(cloudDate) {
						if err = backup(dir, file, "cloud", theirs); err == nil {
							if err = s.upload(name, file, data, localHash, modTime(dir, file)); err == nil {
								manifest[name], manifest["core:"+name] = localHash, localCore
							}
						}
					} else if err = writeSave(dir, file, theirs, true); err == nil {
						manifest[name], manifest["core:"+name] = cloudHash, coreHash(theirs)
					}
					if err == nil {
						conflicts++
						fmt.Println("  ⇅", strings.TrimSuffix(file, ".sav"), "(modifiée des deux côtés : la plus récente gardée, l'autre dans backups)")
					}
				}
			}
		}
		if err != nil && firstErr == nil {
			firstErr = fmt.Errorf("%s : %w", file, err)
		}
		// The old name-keyed copy, now under its game's key: the save as it stands goes up under the key (when
		// the old copy was the cloud's only one), then the old copy goes.
		if old, ok := moved[name]; ok && err == nil && !pushOnly {
			if cur := cloud[name]; cur.id == old.id {
				if final, rerr := os.ReadFile(filepath.Join(dir, "saves", file)); rerr == nil && len(final) > 0 {
					h := hashOf(final)
					if err = s.upload(name, file, final, h, modTime(dir, file)); err == nil {
						manifest[name], manifest["core:"+name] = h, coreHash(final)
					}
				} else {
					err = fmt.Errorf("pas de sauvegarde à renommer")
				}
			}
			if err == nil {
				s.remove(old)
			} else if firstErr == nil {
				firstErr = fmt.Errorf("%s : %w", file, err)
			}
		}
	}
	if !pushOnly {
		syncHistory(s, dir, fileOf, manifest)
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
