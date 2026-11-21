package main

// COMPATIBLE GAMES on PC: the iPhone app's list (App/Library/compat.json, shipped beside Capsule.exe) turned into
// DATA/capsule/compat.txt for PokeDaisy's game list (its X / Y: linux/main.c's compat_load in the fork). The player's
// own games first, recognised by their SHA-1 (kept per file version in capsule/sha1.json) or, for an official cart of
// its own size, by its header; then every game Capsule knows. One line a row: "H" (a group's title) or "G" (a game),
// the row, its details ("\n" between lines), tab-separated. Titles and checksums only, never where to get a game.

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type compatBase struct {
	Code     *string `json:"code"`
	Rev      *int    `json:"rev"`
	Official *string `json:"official"`
	Title    string  `json:"title"`
}

type compatGame struct {
	Title      string      `json:"title"`
	Console    string      `json:"console"`
	Kind       string      `json:"kind"`
	Version    string      `json:"version"`
	Code       *string     `json:"code"`
	Revisions  []int       `json:"revisions"`
	Sha1       []string    `json:"sha1"`
	Companion  bool        `json:"companion"`
	Pokedaisy  bool        `json:"pokedaisy"`
	Bank       string      `json:"bank"`
	Unverified bool        `json:"unverified"`
	Note       *string     `json:"note"`
	Base       *compatBase `json:"base"`
}

type compatOwned struct {
	code  string
	rev   int
	title string
}

func (g compatGame) name() string {
	if g.Version != "" {
		return g.Title + " (" + g.Version + ")"
	}
	return g.Title
}

func yesNo(v string) string {
	switch v {
	case "yes":
		return "oui"
	case "likely":
		return "probable"
	}
	return "non"
}

// baseState: "have", "rev N" (another revision in the library) or "missing".
func baseState(b compatBase, owned []compatOwned) string {
	if b.Code != nil {
		other := -1
		for _, o := range owned {
			if o.code != *b.Code {
				continue
			}
			if b.Rev == nil || o.rev == *b.Rev {
				return "have"
			}
			other = o.rev
		}
		if other >= 0 {
			return fmt.Sprintf("rev %d", other)
		}
		return "missing"
	}
	for _, o := range owned {
		if b.Official != nil && o.title == *b.Official {
			return "have"
		}
	}
	return "missing"
}

func compatDetails(g compatGame, owned []compatOwned, sha string) string {
	kind := "Jeu officiel"
	if g.Kind == "hack" {
		kind = "Hack"
	}
	lines := []string{kind, "Compagnon sur PC : " + yesNo(map[bool]string{true: "yes"}[g.Companion]),
		"Compagnon PokeDaisy (Android) : " + yesNo(map[bool]string{true: "yes"}[g.Pokedaisy]),
		"Banque Capsule : " + yesNo(g.Bank)}
	if g.Base != nil {
		lines = append(lines, "ROM d'origine : "+g.Base.Title)
		switch st := baseState(*g.Base, owned); {
		case st == "have":
			lines = append(lines, "Elle est dans tes jeux : glisse le patch sur la liste pour créer le hack.")
		case strings.HasPrefix(st, "rev "):
			lines = append(lines, "Tu as une autre révision ("+strings.TrimPrefix(st, "rev ")+") : ce hack demande celle indiquée.")
		default:
			lines = append(lines, "Elle n'est pas dans tes jeux.")
		}
	}
	if g.Note != nil {
		lines = append(lines, *g.Note)
	} else if g.Unverified {
		lines = append(lines, "Reconnu, pas encore vérifié en jeu.")
	}
	if sha != "" {
		lines = append(lines, "Empreinte SHA-1 : "+sha)
	}
	return strings.Join(lines, `\n`)
}

// romHeader: the cart's code and revision (GBA at 0xAC / 0xBC, DS at 0x0C / 0x1E); ok false for anything else.
func romHeader(path string) (code string, rev int, ok bool) {
	ext := strings.ToLower(filepath.Ext(path))
	at, r := -1, -1
	switch ext {
	case ".nds":
		at, r = 0x0C, 0x1E
	case ".gba":
		at, r = 0xAC, 0xBC
	default:
		return "", 0, false
	}
	f, err := os.Open(path)
	if err != nil {
		return "", 0, false
	}
	defer f.Close()
	head := make([]byte, 0x200)
	if _, err := io.ReadFull(f, head); err != nil {
		return "", 0, false
	}
	return string(head[at : at+4]), int(head[r]), true
}

func fileSha1(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha1.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// clean: no tab or new line inside a row, and the accents PokeDaisy's font lacks (it has é) as their plain letter.
func clean(s string) string {
	return strings.NewReplacer("\t", " ", "\n", " ", "\r", " ",
		"à", "a", "â", "a", "ä", "a", "è", "e", "ê", "e", "ë", "e", "î", "i", "ï", "i", "ô", "o", "ö", "o",
		"ù", "u", "û", "u", "ü", "u", "ç", "c", "À", "A", "É", "E", "È", "E", "Ê", "E", "Ç", "C").Replace(s)
}

// writeCompat writes DATA/capsule/compat.txt from compat.json beside Capsule.exe; nothing without it.
func writeCompat(dir string) error {
	data, err := os.ReadFile(filepath.Join(dir, "compat.json"))
	if err != nil {
		return err
	}
	var file struct {
		Games []compatGame `json:"games"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		return err
	}
	cachePath := filepath.Join(dir, "capsule", "sha1.json")
	cache := loadManifest(cachePath)
	changed := false

	type mine struct {
		file  string
		match *compatGame
		sha   string
	}
	var games []mine
	var owned []compatOwned
	entries, _ := os.ReadDir(filepath.Join(dir, "roms"))
	sort.Slice(entries, func(i, j int) bool { return strings.ToLower(entries[i].Name()) < strings.ToLower(entries[j].Name()) })
	for _, e := range entries {
		info, err := e.Info()
		if e.IsDir() || err != nil || !romExts[strings.ToLower(filepath.Ext(e.Name()))] {
			continue
		}
		path := filepath.Join(dir, "roms", e.Name())
		stamp := fmt.Sprintf("%s|%d|%d", e.Name(), info.Size(), info.ModTime().Unix())
		sha := cache[stamp]
		if sha == "" {
			if sha, err = fileSha1(path); err != nil {
				continue
			}
			cache[stamp] = sha
			changed = true
		}
		var match *compatGame
		for i := range file.Games {
			for _, s := range file.Games[i].Sha1 {
				if s == sha {
					match = &file.Games[i]
				}
			}
			if match != nil {
				break
			}
		}
		code, rev, ok := romHeader(path)
		// A hack keeps its base game's header: only an official cart's own size counts as that cart.
		if match == nil && ok && (strings.EqualFold(filepath.Ext(path), ".nds") || info.Size() <= 16<<20) {
			for i := range file.Games {
				g := &file.Games[i]
				if g.Kind != "official" || g.Code == nil || *g.Code != code {
					continue
				}
				in := g.Revisions == nil
				for _, r := range g.Revisions {
					in = in || r == rev
				}
				if in {
					match = g
					break
				}
			}
		}
		if match != nil && match.Kind == "official" {
			owned = append(owned, compatOwned{code: code, rev: rev, title: match.Title})
		}
		games = append(games, mine{e.Name(), match, sha})
	}
	if changed {
		os.MkdirAll(filepath.Dir(cachePath), 0o755)
		if b, err := json.Marshal(cache); err == nil {
			os.WriteFile(cachePath, b, 0o644)
		}
	}

	var out strings.Builder
	row := func(kind, text, details string) {
		out.WriteString(kind + "\t" + clean(text) + "\t" + clean(details) + "\n")
	}
	row("H", "+ : le compagnon marche sur PC   A : détails", "")
	if len(games) > 0 {
		row("H", fmt.Sprintf("TES JEUX · %d", len(games)), "")
		for _, m := range games {
			if m.match == nil {
				row("G", "  "+m.file, "Version inconnue : il se joue, sans compagnon ; la banque ne l'ouvre que si sa sauvegarde a un format connu.\\nEmpreinte SHA-1 : "+m.sha)
				continue
			}
			mark := "  "
			if m.match.Companion {
				mark = "+ "
			}
			row("G", mark+m.file, "Reconnu : "+m.match.name()+`\n`+compatDetails(*m.match, owned, m.sha))
		}
	}
	for _, c := range []struct{ id, name string }{{"GBA", "GAME BOY ADVANCE"}, {"GB", "GAME BOY / COLOR"}, {"DS", "NINTENDO DS"}} {
		var list []compatGame
		for _, g := range file.Games {
			if g.Console == c.id {
				list = append(list, g)
			}
		}
		if len(list) == 0 {
			continue
		}
		row("H", fmt.Sprintf("%s · %d", c.name, len(list)), "")
		for _, g := range list {
			mark := "  "
			if g.Companion {
				mark = "+ "
			}
			label := g.name()
			if g.Kind == "hack" {
				label += "  [hack]"
			}
			row("G", mark+label, compatDetails(g, owned, ""))
		}
	}
	row("H", "La liste dit ce que Capsule reconnaît, jamais où trouver un jeu.", "")
	os.MkdirAll(filepath.Join(dir, "capsule"), 0o755)
	return os.WriteFile(filepath.Join(dir, "capsule", "compat.txt"), []byte(out.String()), 0o644)
}
