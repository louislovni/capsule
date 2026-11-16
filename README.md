# Capsule

Émulateur Game Boy Advance pour iPhone, pensé pour les jeux Pokémon de 3ᵉ génération
(Rubis, Saphir, Émeraude, Rouge Feu, Vert Feuille, toutes langues occidentales).

- **Émulation** : cœur [mGBA](https://mgba.io), son, commandes tactiles, vitesse ×2 / ×4, trois états de sauvegarde.
- **Compagnon** : l'équipe lue en direct dans la mémoire du jeu (PV, statut, niveau, capacités), et un soin de l'équipe hors combat.
- **Banque** : dépose les Pokémon des boîtes PC d'une partie, retire-les dans une autre. La banque est un fichier exportable.

Aucun jeu n'est fourni : il faut tes propres ROM.

## État du projet

Première version, **jamais encore compilée pour iOS ni lancée sur un iPhone**.

| Partie | Vérifié | Comment |
|---|---|---|
| Cœur C (sauvegardes, structures Pokémon, banque) | Oui, sur données synthétiques | 523 vérifications automatiques, aussi sous AddressSanitizer |
| Pont mGBA (image, son, touches, états, mémoire) | Oui, sous Linux | ROM de test minuscule assemblée par le test |
| Adresses mémoire par jeu | Non | Reprises des données de PokeDaisy, pas testées ici avec de vrais jeux |
| Vraies sauvegardes et vraies ROM | Non | Aucun jeu disponible pendant le développement |
| App iOS (Swift) | Syntaxe seulement | Pas de compilateur Swift ni de Mac disponibles |
| Compilation GitHub Actions | Non | Jamais exécutée |

Attends-toi donc à des erreurs de compilation au premier passage sur GitHub, puis à des
défauts à l'usage. La banque fait une copie de secours de la sauvegarde avant d'y écrire
(dossier `Backups`), mais **garde aussi ta propre copie de tes `.sav`** tant que rien n'a été
validé sur de vrais jeux.

## Obtenir l'IPA sans Mac

1. Crée un dépôt **public** sur GitHub et envoies-y le contenu de ce dossier (branche `main`).
   La compilation sur Mac est gratuite pour les dépôts publics.
2. Onglet **Actions** : le flux « Build IPA » démarre à chaque envoi. Tu peux aussi le lancer à la main.
3. Quand il est vert, ouvre l'exécution et télécharge l'artefact **Capsule-ipa** (un zip contenant `Capsule.ipa`).
4. Installe l'IPA depuis ton PC avec AltStore, SideStore ou Sideloadly et ton identifiant Apple.
   Avec un compte gratuit, il faut la re-signer tous les 7 jours.

Si le flux échoue, l'artefact **xcodebuild-log** contient le détail de l'erreur.

## Utilisation

- **Importer** : bouton + de l'écran d'accueil, ou dépose les fichiers dans l'app Fichiers,
  `Sur mon iPhone > Capsule > ROMs` (jeux `.gba`, non compressés) et `Saves` (sauvegardes `.sav`
  portant le même nom que la ROM).
- **Jouer** : touche un jeu. La barre du haut donne la pause, la vitesse, l'équipe et un menu
  (états, soin, redémarrage).
- **Banque** : touche l'icône de boîte à côté d'un jeu, **jeu fermé**. Seuls les Pokémon rangés
  dans le PC peuvent être déposés. Un Pokémon retiré arrive dans la première place libre du PC.

### À savoir sur la banque

- Elle modifie le fichier de sauvegarde. Sauvegarde dans le jeu avant de l'ouvrir.
- Après un transfert, repars de la sauvegarde du jeu. Charger un **état** enregistré avant le
  transfert puis sauvegarder en jeu remettrait le PC d'avant ; l'app te prévient dans ce cas.
- Les sauvegardes dont le PC n'a pas le format des jeux d'origine (certains hacks) sont refusées.
- Elle n'est **pas encore en ligne** : le fichier `Bank/banque.json` s'exporte (bouton de partage)
  et se réimporte par le bouton +, qui fusionne sans doublon.

## Organisation du code

```
App/            l'app iOS (SwiftUI)
Core/bridge/    le pont C entre mGBA et l'app
Core/pkcore/    sauvegardes, structures Pokémon, recherche en mémoire (C portable)
Core/tests/     tests, exécutables sur n'importe quel Unix
scripts/        build_core.sh : télécharge mGBA et compile le tout
tools/          gen_profiles.py : régénère la table d'adresses depuis PokeDaisy
project.yml     description du projet Xcode (XcodeGen)
```

Lancer les tests sur un PC Linux ou WSL (il faut `git`, `cmake` et un compilateur C) :

```
sh scripts/build_core.sh host
```

## Suite prévue

- Banque synchronisée en ligne.
- Codes de triche, patchs IPS/UPS/BPS pour les ROM hacks, manettes Bluetooth.
- Confort de jeu façon PokeDaisy (PC partout, Repousse, rencontres coupées).
- Vue 3D « voxel » : expérimentale, bien plus tard.

## Licence

GPL v3 (voir `LICENSE` et `NOTICE`). mGBA est sous MPL 2.0 ; la table d'adresses vient de
[PokeDaisy](https://pokedaisy.com) (GPL v3).
