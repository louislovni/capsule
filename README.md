# Capsule

Le compagnon de [PokeDaisy](https://pokedaisy.com) sur iPhone, avec une banque Pokémon en plus.

Les jeux tournent sur le cœur libretro de PokeDaisy : mGBA avec, intégrés, son compagnon (équipe,
sac, carte, Pokédex, guide, combat), son HUD, son menu rapide (PC, Vol, Repousse, vélo, rencontres),
EXPAND et ses autres outils. Capsule fournit l'enveloppe iOS (image, son, boutons, toucher,
sauvegardes, états, vitesse) et la **banque** : déposer les Pokémon du PC d'une partie et les
retirer dans une autre de la même génération, avec une fiche détaillée.

Game Boy Advance, Game Boy, Game Boy Color et Nintendo DS. Aucun jeu n'est fourni : il faut tes
propres ROM.
Capsule n'est ni fait ni approuvé par les auteurs de PokeDaisy.

## Commandes

- **GBA / Game Boy** : **X** ouvre le compagnon de PokeDaisy, **Y** son menu rapide.
- **DS** : A, B, X, Y sont ceux du jeu. La rangée entre L et R donne COMPAGNON, MENU (menu
  rapide), ÉCRANS (passe d'une disposition à l'autre : un seul écran, côte à côte...) et TACTILE
  (fait apparaître l'écran tactile). Le cœur DS tourne sans JIT (iOS l'interdit) : il lui faut un
  iPhone récent.
- **Toucher l'image** agit sur le compagnon et le HUD.
- La barre du haut : pause, vitesse ×1 / ×2 / ×4, états de sauvegarde, redémarrage.
- **Tourne le téléphone** pour jouer en plein écran : l'image prend toute la hauteur et les boutons
  se posent dessus, en transparence ; toucher l'image hors des boutons agit toujours sur le jeu.

## État du projet

- **Banque, fiches, sauvegardes Gen 1 à 3** : tests automatiques sur données fabriquées ; la banque
  fait une copie de secours de chaque sauvegarde avant d'y écrire (dossier `Backups`). Garde quand même
  ta propre copie de tes `.sav`.
- **Hôte du cœur PokeDaisy** : testé sous Linux sur des ROM de test (image, son, états, sauvegarde) ;
  le compagnon lui-même n'a pas encore tourné sur iPhone avec un vrai jeu.
- **DS** : le cœur DS de PokeDaisy (DSperate) passe ses propres tests sans JIT et tourne dans l'hôte
  sous Linux. Son compagnon reconnaît Platine (US rév. 1), HeartGold / SoulSilver (US) et
  Noir / Blanc 1 et 2 (US / Europe) en anglais ; les autres versions se jouent sans compagnon.
  La banque ne gère pas encore la DS.

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
  `Sur mon iPhone > Capsule > ROMs` (jeux `.gba`, `.gb`, `.gbc`, non compressés) et `Saves` (sauvegardes `.sav`
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
