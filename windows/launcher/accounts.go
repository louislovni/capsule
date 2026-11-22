package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Each account keeps its own saves on this PC: "saves" and "states" are the signed-in account's, and an account
// signed out of has its folders put away in capsule/comptes/<uid>/ until it signs in again. So switching
// accounts never sends one account's saves into another's cloud. The account the folders belong to is
// capsule/compte-actif.txt (its UID).

func activePath(dir string) string { return filepath.Join(dir, "capsule", "compte-actif.txt") }

func activeAccount(dir string) string {
	data, err := os.ReadFile(activePath(dir))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func setActiveAccount(dir, uid string) error {
	os.MkdirAll(filepath.Join(dir, "capsule"), 0o700)
	return os.WriteFile(activePath(dir), []byte(uid+"\n"), 0o600)
}

// signOut: the session goes; the folders stay the signed-out account's (marked as such) until another signs in.
func signOut(dir string) {
	if activeAccount(dir) == "" {
		// A PC signed in before folders were kept per account: the folders are that session's account's.
		if data, err := os.ReadFile(sessionPath(dir)); err == nil {
			var a struct {
				UID string `json:"uid"`
			}
			if json.Unmarshal(data, &a) == nil && a.UID != "" {
				setActiveAccount(dir, a.UID)
			}
		}
	}
	os.Remove(sessionPath(dir))
}

// useAccountFolders: [uid] signed in. Another account's folders are put away and [uid]'s own come back (or empty
// ones, which the sync then fills from its cloud).
func useAccountFolders(dir, uid string) error {
	cur := activeAccount(dir)
	if cur == "" || cur == uid {
		return setActiveAccount(dir, uid)
	}
	fmt.Println("Autre compte : les sauvegardes du compte précédent sont mises de côté sur ce PC.")
	for _, sub := range []string{"saves", "states"} {
		live := filepath.Join(dir, sub)
		away := filepath.Join(dir, "capsule", "comptes", cur, sub)
		os.MkdirAll(filepath.Dir(away), 0o700)
		if _, err := os.Stat(away); err == nil {
			// left over (a crash mid-switch): kept beside, never overwritten
			os.Rename(away, away+"-"+time.Now().Format("20060102-150405"))
		}
		if _, err := os.Stat(live); err == nil {
			if err := os.Rename(live, away); err != nil {
				return fmt.Errorf("le dossier %s n'a pas pu être mis de côté (un jeu est encore ouvert ?) : %v", sub, err)
			}
		}
		back := filepath.Join(dir, "capsule", "comptes", uid, sub)
		if _, err := os.Stat(back); err == nil {
			if err := os.Rename(back, live); err != nil {
				return fmt.Errorf("le dossier %s de ce compte n'a pas pu revenir : %v", sub, err)
			}
		} else {
			os.MkdirAll(live, 0o755)
		}
	}
	return setActiveAccount(dir, uid)
}
