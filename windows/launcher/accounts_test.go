package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSwitchingAccountsKeepsEachOnesSaves(t *testing.T) {
	dir := t.TempDir()
	write := func(rel, s string) {
		p := filepath.Join(dir, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(s), 0o644)
	}
	read := func(rel string) string {
		b, err := os.ReadFile(filepath.Join(dir, rel))
		if err != nil {
			return ""
		}
		return string(b)
	}
	// A PC signed in as A before folders were per account: its session names A.
	write("saves/Emeraude.sav", "A's save")
	write("capsule/compte.json", `{"uid":"A","email":"a@x","refreshToken":"t"}`)
	signOut(dir)
	if activeAccount(dir) != "A" || read("capsule/compte.json") != "" {
		t.Fatal("sign-out: the folders should be A's, the session gone")
	}
	if err := useAccountFolders(dir, "B"); err != nil {
		t.Fatal(err)
	}
	if read("saves/Emeraude.sav") != "" || read("capsule/comptes/A/saves/Emeraude.sav") != "A's save" {
		t.Fatal("B should start with empty saves, A's put away")
	}
	write("saves/Emeraude.sav", "B's save")
	if err := useAccountFolders(dir, "A"); err != nil {
		t.Fatal(err)
	}
	if read("saves/Emeraude.sav") != "A's save" || read("capsule/comptes/B/saves/Emeraude.sav") != "B's save" {
		t.Fatal("A's saves should come back, B's put away")
	}
	if err := useAccountFolders(dir, "A"); err != nil || read("saves/Emeraude.sav") != "A's save" {
		t.Fatal("the same account again changes nothing")
	}
}
