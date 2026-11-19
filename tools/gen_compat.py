#!/usr/bin/env python3
"""Writes App/Library/compat.json: the games Capsule knows on iPhone, from the PokeDaisy fork's own tables.

  python3 tools/gen_compat.py <PokeDaisy fork checkout>

What each game gets in Capsule:
- companion: the iPhone cores' companion recognises it (3ds/core/pd_game.c for GBA / Game Boy by SHA-1 or cart code,
  linux/dsperate/companion.cpp for DS: the US carts by SHA-1, the French ones by header);
- bank: the bank and Pokédex read its save: "yes" (checked layouts), "likely" (a hack edited in place of an official
  game, its save the official layout), "no" (a hack whose save is laid out its own way).
Versions come from the site's compat.json. Titles and checksums only: never where to get a game.
"""
import json, os, re, sys

fork = sys.argv[1]
src = open(os.path.join(fork, "3ds/core/pd_game.c"), encoding="utf-8").read()
site = json.load(open(os.path.join(fork, "website/src/data/compat.json"), encoding="utf-8"))
versions = {h["sha1"]: h.get("version", "") for h in site["hacks"]}

# Hacks whose save keeps the official game's layout (edited in place, the official species list).
IN_PLACE = {"PD_CONFIG_EMERALD", "PD_CONFIG_SAPPHIRE", "PD_CONFIG_EMERALD_LEGACY", "PD_CONFIG_EMERALD_KAIZO",
            "PD_CONFIG_CELIA", "PD_CONFIG_ORANGE_ISLANDS", "PD_CONFIG_ULTRA_VIOLET", "PD_CONFIG_ROCKET_EDITION",
            "PD_CONFIG_ASH_GRAY", "PD_CONFIG_GHOST_GREY", "PD_CONFIG_TEAM_ROCKET"}

def clean(title):
    unverified = "(unverified)" in title
    return title.replace(" (unverified)", "").strip(), unverified

games = []
def add(**g):
    games.append(g)

# Game Boy Advance, official carts (every language the companion has a config for).
for r in site["retail"]:
    add(title=r["title"], console="GBA", kind="official", version="", revisions=r["revs"], code=r["code"],
        sha1=[], companion=True, bank="yes")

# Game Boy Advance hacks (by SHA-1).
hacks = {}
for sha, cfg, _kind, title in re.findall(r'\{"([0-9a-f]{40})", &(PD_CONFIG_\w+), (PD_GAME_\w+), "([^"]+)"', src):
    name, unverified = clean(title)
    key = (name, versions.get(sha, ""))
    entry = hacks.setdefault(key, dict(title=name, console="GBA", kind="hack", version=versions.get(sha, ""),
                                       sha1=[], companion=True, bank="likely" if cfg in IN_PLACE else "no",
                                       unverified=unverified))
    entry["sha1"].append(sha)
games += hacks.values()

# Game Boy / Game Boy Color (official and hacks, by SHA-1).
OFFICIAL_GB = ("Pokémon Red", "Pokémon Blue", "Pokémon Yellow", "Pokémon Gold", "Pokémon Silver", "Pokémon Crystal",
               "Gelbe", "Jaune", "Gialla", "Amarilla")
gb = {}
for sha, _cfg, title in re.findall(r'\{"([0-9a-f]{40})", &(PD_GB_CONFIG_\w+), "([^"]+)"\}', src):
    name, unverified = clean(title)
    official = name in OFFICIAL_GB or any(word in name for word in ("Gelbe", "Jaune", "Gialla", "Amarilla"))
    entry = gb.setdefault(name, dict(title=name, console="GB", kind="official" if official else "hack", version="",
                                      sha1=[], companion=True, bank="yes" if official else "no", unverified=unverified))
    entry["sha1"].append(sha)
games += gb.values()

# DS: the companion on iPhone knows the US carts (by SHA-1) and the French ones (by header); the others play without
# it. The bank reads every language's save.
US = {"CPUE": "Pokémon Platinum", "IPKE": "Pokémon HeartGold", "IPGE": "Pokémon SoulSilver", "IRBO": "Pokémon Black",
      "IRAO": "Pokémon White", "IREO": "Pokémon Black 2", "IRDO": "Pokémon White 2"}
FR = {"CPUF", "IPKF", "IPGF", "IRBF", "IRAF", "IREF", "IRDF"}
seen = set()
for r in site["ds"]:
    if r["code"] in seen:
        continue
    seen.add(r["code"])
    add(title=r["title"], console="DS", kind="official", version="", code=r["code"], revisions=[r["rev"]], sha1=[],
        companion=r["code"] in US or r["code"] in FR, bank="yes")
for h in site["dsHacks"]:
    bank = {"Pokémon Renegade Platinum": "likely", "Pokémon Blaze Black 2 Redux": "likely",
            "Pokémon Volt White 2 Redux": "likely", "Pokémon Heartfelt Gold": "likely"}.get(h["title"], "no")
    add(title=h["title"], console="DS", kind="hack", version=h.get("version", ""), sha1=[], companion=False, bank=bank,
        note="Compagnon sur Android seulement")
add(title="Pokémon Chaos Purple", console="DS", kind="hack", version="démo (Silph Co. fix)",
    sha1=["330d9eb56e069df13c09bbcb3c748c269c94a88e"], companion=False, bank="yes",
    note="Banque et Pokédex vérifiés sur une sauvegarde ; Pokémon après Arceus réservés aux jeux du même moteur")

order = {"GBA": 0, "GB": 1, "DS": 2}
games.sort(key=lambda g: (order[g["console"]], g["kind"] != "official", g["title"], g.get("version", "")))
out = os.path.join(os.path.dirname(__file__), "..", "App", "Library", "compat.json")
json.dump({"generatedFrom": "PokeDaisy fork, 3ds/core/pd_game.c and website/src/data/compat.json", "games": games},
          open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(len(games), "games ->", os.path.normpath(out))
