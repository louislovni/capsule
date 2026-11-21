// Capsule for Windows: signs in to the Capsule account, brings the saves in from the cloud,
// starts PokeDaisy (pokedaisy.exe, beside this program) and sends the saves back when it closes.
// Same account, same files and same rules as the iPhone app (App/Online/CloudSync.swift).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// Set at build time (-ldflags -X): the Google OAuth client of type "Desktop app".
var (
	googleClientID     = ""
	googleClientSecret = ""
	version            = "dev"
)

func main() {
	exe, err := os.Executable()
	if err != nil {
		fail(err)
	}
	dir := filepath.Dir(exe)
	for _, sub := range []string{"roms", "saves", "states"} {
		os.MkdirAll(filepath.Join(dir, sub), 0o755)
	}
	fmt.Printf("Capsule %s pour Windows\n\n", version)

	args := os.Args[1:]
	if len(args) > 0 && (args[0] == "--deconnexion" || args[0] == "--logout") {
		os.Remove(sessionPath(dir))
		fmt.Println("Déconnecté. Au prochain lancement, Capsule redemandera ton compte Google.")
		pause()
		return
	}
	offline := len(args) > 0 && args[0] == "--hors-ligne"

	var account *Account
	if !offline {
		account, err = signIn(dir)
		if err != nil {
			fmt.Println("Connexion impossible :", err)
			fmt.Println("Le jeu se lance quand même, sans synchronisation.")
			fmt.Println()
		}
	}
	if account != nil {
		syncNow(dir, account, "Récupération des sauvegardes du cloud…")
	}

	// COMPATIBLE GAMES in PokeDaisy's game list (X / Y): the list beside this program, the player's games recognised.
	if err := writeCompat(dir); err != nil && !os.IsNotExist(err) {
		fmt.Println("Liste des jeux compatibles indisponible :", err)
	}

	game := filepath.Join(dir, "pokedaisy.exe")
	cmd := exec.Command(game, "--data", dir)
	cmd.Dir = dir
	cmd.Stdout = nil
	cmd.Stderr = nil
	if account != nil {
		fmt.Println("PokeDaisy est lancé. Chaque sauvegarde faite dans le jeu part dans le cloud quelques secondes après.")
	} else {
		fmt.Println("PokeDaisy est lancé.")
	}
	done := make(chan struct{})
	watching := make(chan struct{})
	if account != nil {
		go func() {
			watchSaves(dir, account, 10*time.Second, 5*time.Second, done)
			close(watching)
		}()
	} else {
		close(watching)
	}
	if err := cmd.Run(); err != nil {
		fmt.Println("PokeDaisy s'est arrêté :", err)
	}
	close(done)
	<-watching // a push under way ends before the last sync

	if account != nil {
		syncNow(dir, account, "Envoi des sauvegardes…")
	}
	fmt.Println("\nÀ bientôt !")
	time.Sleep(2 * time.Second)
}

func syncNow(dir string, account *Account, title string) {
	fmt.Println(title)
	report, err := syncSaves(dir, account)
	if err != nil {
		fmt.Println("  Échec de la synchronisation :", err)
		fmt.Println()
		return
	}
	fmt.Println(" ", report)
	fmt.Println()
}

func fail(err error) {
	fmt.Println("Erreur :", err)
	pause()
	os.Exit(1)
}

func pause() {
	fmt.Println("\nAppuie sur Entrée pour fermer.")
	var line string
	fmt.Scanln(&line)
}

func plural(n int, one, many string) string {
	if n > 1 {
		return fmt.Sprintf("%d %s", n, many)
	}
	return fmt.Sprintf("%d %s", n, one)
}
