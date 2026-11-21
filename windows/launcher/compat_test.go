package main

import (
	"crypto/sha1"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// compat.txt: an official cart recognised by its header, a hack by its SHA-1 with its base in the library, an unknown file.
func TestWriteCompat(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "roms"), 0o755)
	cart := make([]byte, 0x400)
	copy(cart[0xAC:], "BPRE")
	cart[0xBC] = 1
	os.WriteFile(filepath.Join(dir, "roms", "FireRed.gba"), cart, 0o644)
	hack := []byte("a hack's bytes")
	os.WriteFile(filepath.Join(dir, "roms", "Hack.gba"), hack, 0o644)
	os.WriteFile(filepath.Join(dir, "roms", "Other.gba"), []byte("other"), 0o644)
	sum := sha1.Sum(hack)
	list := `{"games": [
	 {"title": "Pokémon FireRed", "console": "GBA", "kind": "official", "version": "", "code": "BPRE", "revisions": [0, 1],
	  "sha1": [], "companion": true, "pokedaisy": true, "bank": "yes"},
	 {"title": "Pokémon Hack", "console": "GBA", "kind": "hack", "version": "1.0", "sha1": ["` + hex.EncodeToString(sum[:]) + `"],
	  "companion": false, "pokedaisy": true, "bank": "likely", "base": {"code": "BPRE", "rev": 0, "title": "Pokémon FireRed (USA)"}}
	]}`
	os.WriteFile(filepath.Join(dir, "compat.json"), []byte(list), 0o644)
	if err := writeCompat(dir); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(filepath.Join(dir, "capsule", "compat.txt"))
	text := string(data)
	for _, want := range []string{
		"G\t+ FireRed.gba\tReconnu : Pokémon FireRed\\nJeu officiel",
		"G\t  Hack.gba\tReconnu : Pokémon Hack (1.0)\\nHack",
		"Banque Capsule : probable",
		"Tu as une autre révision (1) : ce hack demande celle indiquée.", // FireRed rev 1 in the library, the hack wants rev 0
		"G\t  Other.gba\tVersion inconnue",
		"H\tGAME BOY ADVANCE · 2\t",
		"G\t  Pokémon Hack (1.0)  [hack]\t",
		"H\tLa liste dit ce que Capsule reconnait, jamais ou trouver un jeu.\t", // the font's missing accents
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in:\n%s", want, text)
		}
	}
	if strings.Count(text, "\n") != strings.Count(text, "\t")/2 {
		t.Errorf("a row with a tab or a new line of its own:\n%s", text)
	}
}
