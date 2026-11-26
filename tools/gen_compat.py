#!/usr/bin/env python3
"""Writes App/Library/compat.json: the games Capsule knows on iPhone, from the PokeDaisy fork's own tables.

  python3 tools/gen_compat.py <PokeDaisy fork checkout>

What each game gets in Capsule:
- pokedaisy: PokeDaisy's own companion (the Android app, and Capsule for Android, built from it) recognises it: the
  site's compat.json (retail codes, hack / Game Boy SHA-1s, DS codes and hacks);
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
pd_hacks = {h["sha1"] for h in site["hacks"]}
pd_gb = {g["sha1"] for g in site["gameBoy"]}
pd_gba_codes = {r["code"] for r in site["retail"]}
pd_ds_codes = {r["code"] for r in site["ds"]}

# Hacks whose save keeps the official game's layout (edited in place, the official species list).
IN_PLACE = {"PD_CONFIG_EMERALD", "PD_CONFIG_SAPPHIRE", "PD_CONFIG_EMERALD_LEGACY", "PD_CONFIG_EMERALD_KAIZO",
            "PD_CONFIG_CELIA", "PD_CONFIG_ORANGE_ISLANDS", "PD_CONFIG_ULTRA_VIOLET", "PD_CONFIG_ROCKET_EDITION",
            "PD_CONFIG_ASH_GRAY", "PD_CONFIG_GHOST_GREY", "PD_CONFIG_TEAM_ROCKET"}

# The ROM a hack's patch goes on (what the player needs; a hack whose author says otherwise is the exception):
# FireRed-engine hacks on FireRed (USA) 1.0 (CFRU and the older binary hacks), Emerald-engine ones on Emerald (USA),
# the DS hacks on their US cart (Origin HeartGold on the Japanese one).
BASES = {
    "BPRE": dict(code="BPRE", rev=0, title="Pokémon FireRed (USA) 1.0"),
    "BPEE": dict(code="BPEE", rev=0, title="Pokémon Emerald (USA)"),
    "AXPE": dict(code="AXPE", rev=None, title="Pokémon Sapphire (USA)"),
    "AXVE": dict(code="AXVE", rev=None, title="Pokémon Ruby (USA)"),
    "CPUE": dict(code="CPUE", rev=1, title="Pokémon Platinum (USA) rev 1"),
    "IPKE": dict(code="IPKE", rev=None, title="Pokémon HeartGold (USA)"),
    "IPKJ": dict(code="IPKJ", rev=0, title="Pokémon HeartGold (Japon)"),
    "IREO": dict(code="IREO", rev=None, title="Pokémon Black 2 (USA)"),
    "IRDO": dict(code="IRDO", rev=None, title="Pokémon White 2 (USA)"),
    # Game Boy: no cart code; [official] is the list's official entry the player's ROM is recognised as.
    "RED": dict(official="Pokémon Red", title="Pokémon Red (USA, Europe)"),
    "BLUE": dict(official="Pokémon Blue", title="Pokémon Blue (USA, Europe)"),
    "YELLOW": dict(official="Pokémon Yellow", title="Pokémon Yellow (USA, Europe)"),
    "CRYSTAL": dict(official="Pokémon Crystal", title="Pokémon Crystal (USA)"),
}
GB_BASES = {"Pokémon Brown": "RED", "Pokémon PureRed": "RED", "Pokémon PureRed 2.7.7": "RED", "Pokémon PureBlue": "BLUE",
            "Pokémon PureBlue 2.7.7": "BLUE", "Pokémon Yellow Legacy": "YELLOW", "Pokémon Crystal Clear": "CRYSTAL",
            "Pokémon Crystal Legacy": "CRYSTAL", "Pokémon Prism": "CRYSTAL"}
DS_BASES = {"Pokémon Origin HeartGold": "IPKJ", "Pokémon Renegade Platinum": "CPUE", "Pokémon Heartfelt Gold": "IPKE",
            "Pokémon Blaze Black 2 Redux": "IREO", "Pokémon Volt White 2 Redux": "IRDO", "Pokémon Chaos Purple": "IPKE"}

def base_for(cfg, kind, title):
    if "SAPPHIRE" in cfg:
        return BASES["AXPE"]
    if "RUBY" in cfg:
        return BASES["AXVE"]
    if kind == "PD_GAME_FIRERED":
        return BASES["BPRE"]
    if kind == "PD_GAME_EMERALD":
        return BASES["BPEE"]
    return title_base(title)

def title_base(title):
    if title in GB_BASES:
        return BASES[GB_BASES[title]]
    if "Emerald" in title or "Émeraude" in title or "Elite Redux" in title:
        return BASES["BPEE"]
    if "FireRed" in title or "Rouge Feu" in title or "Let's Go" in title:
        return BASES["BPRE"]
    return None

def clean(title):
    unverified = "(unverified)" in title
    return title.replace(" (unverified)", "").strip(), unverified

games = []
def add(**g):
    games.append(g)

# Game Boy Advance, official carts (every language the companion has a config for).
for r in site["retail"]:
    add(title=r["title"], console="GBA", kind="official", version="", revisions=r["revs"], code=r["code"],
        sha1=[], companion=True, pokedaisy=True, bank="yes")

# The English FireRed and Emerald: the site keeps them apart, as the hacks' bases.
for code, title in site["baseCodes"].items():
    add(title=title, console="GBA", kind="official", version="", revisions=[0, 1] if code == "BPRE" else [0],
        code=code, sha1=[], companion=True, pokedaisy=True, bank="yes")

# Game Boy Advance hacks (by SHA-1).
hacks = {}
for sha, cfg, kind, title in re.findall(r'\{"([0-9a-f]{40})", &(PD_CONFIG_\w+), (PD_GAME_\w+), "([^"]+)"', src):
    name, unverified = clean(title)
    key = (name, versions.get(sha, ""))
    entry = hacks.setdefault(key, dict(title=name, console="GBA", kind="hack", version=versions.get(sha, ""),
                                       sha1=[], companion=True, pokedaisy=False,
                                       bank="likely" if cfg in IN_PLACE else "no", unverified=unverified,
                                       base=base_for(cfg, kind, name)))
    entry["sha1"].append(sha)
    entry["pokedaisy"] = entry["pokedaisy"] or sha in pd_hacks
games += hacks.values()
# Hacks only PokeDaisy's (Android) companion knows.
ios_gba = {sha for g in hacks.values() for sha in g["sha1"]}
android_only = {}
for h in site["hacks"]:
    if h["sha1"] in ios_gba:
        continue
    key = (h["title"], h.get("version", ""))
    entry = android_only.setdefault(key, dict(title=h["title"], console="GBA", kind="hack", version=h.get("version", ""),
                                              sha1=[], companion=False, pokedaisy=True, bank="no",
                                              base=title_base(h["title"])))
    entry["sha1"].append(h["sha1"])
games += android_only.values()

# Game Boy / Game Boy Color (official and hacks, by SHA-1).
OFFICIAL_GB = ("Pokémon Red", "Pokémon Blue", "Pokémon Yellow", "Pokémon Gold", "Pokémon Silver", "Pokémon Crystal",
               "Gelbe", "Jaune", "Gialla", "Amarilla")
gb = {}
for sha, _cfg, title in re.findall(r'\{"([0-9a-f]{40})", &(PD_GB_CONFIG_\w+), "([^"]+)"\}', src):
    name, unverified = clean(title)
    official = name in OFFICIAL_GB or any(word in name for word in ("Gelbe", "Jaune", "Gialla", "Amarilla"))
    entry = gb.setdefault(name, dict(title=name, console="GB", kind="official" if official else "hack", version="",
                                      sha1=[], companion=True, pokedaisy=False, bank="yes" if official else "no",
                                      unverified=unverified, base=None if official else title_base(name)))
    entry["sha1"].append(sha)
    entry["pokedaisy"] = entry["pokedaisy"] or sha in pd_gb
games += gb.values()
ios_gb = {sha for g in gb.values() for sha in g["sha1"]}
for g in site["gameBoy"]:
    if g["sha1"] in ios_gb:
        continue
    # The other languages' official carts (German Red, Gold...) and the hacks only PokeDaisy reads.
    official = any(w in g["title"] for w in ("Rote Edition", "Blaue Edition", "Goldene Edition", "Silberne Edition",
                                             "Kristall", "Rouge", "Bleue", "Version Or", "Version Argent", "Cristal",
                                             "Versione Rossa", "Versione Blu", "Versione Oro", "Versione Argento",
                                             "Edición Roja", "Edición Azul", "Edición Oro", "Edición Plata"))
    add(title=g["title"], console="GB", kind="official" if official else "hack", version="", sha1=[g["sha1"]],
        companion=False, pokedaisy=True, bank="likely" if official else "no",
        base=None if official else title_base(g["title"]))

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
        companion=r["code"] in US or r["code"] in FR, pokedaisy=r["code"] in pd_ds_codes, bank="yes")
for h in site["dsHacks"]:
    if h["title"] == "Pokémon Chaos Purple":
        continue   # added below, with its SHA-1 and save notes
    bank = {"Pokémon Renegade Platinum": "likely", "Pokémon Blaze Black 2 Redux": "likely",
            "Pokémon Volt White 2 Redux": "likely", "Pokémon Heartfelt Gold": "likely"}.get(h["title"], "no")
    # Origin HeartGold rc8: the iPhone / PC companion knows it by its code (linux/dsperate/companion.cpp, ds_origin_cart).
    origin = h["title"] == "Pokémon Origin HeartGold"
    # Heartfelt Gold: by its header (ds_hg_engine_cart, hg-engine's ARM9 and overlay table), as Chaos Purple.
    heartfelt = h["title"] == "Pokémon Heartfelt Gold"
    add(title=h["title"], console="DS", kind="hack", version=h.get("version", ""),
        sha1=["a54a647599d59ed0060dfc4375c289d6e041318a"] if origin else [], companion=origin or heartfelt,
        pokedaisy=True, bank=bank, base=BASES.get(DS_BASES.get(h["title"], "")))
add(title="Pokémon Chaos Purple", console="DS", kind="hack", version="démo (Silph Co. fix)",
    sha1=["330d9eb56e069df13c09bbcb3c748c269c94a88e"], companion=True, pokedaisy=True, bank="yes",
    note="Banque et Pokédex vérifiés sur une sauvegarde ; Pokémon après Arceus réservés aux jeux du même moteur",
    base=BASES["IPKE"])

# French and English versions only (the player's call): a cart by its code's region letter (E USA, P Europe, O
# international, F France), a hack or a Game Boy cart by its title / version's language.
OTHER_LANGUAGES = ("Gelbe", "Rote", "Blaue", "Goldene", "Silberne", "Kristall", "Schwarze", "Weiße", "Weisse",
                   "Feuerrote", "Blattgrüne", "Rubin", "Smaragd", "Saphir-", "Platin-", "Perl-", "Diamant-",
                   "Versione", "Edición", "Edicion", "(Japan)", "(Korea)", "(ES)", "(DE)", "(IT)", "(JP)")
def french_or_english(g):
    if g.get("code"):
        if g["code"][3] not in "EPOF":
            return False
    text = g["title"] + " " + g.get("version", "")
    if any(word in text for word in OTHER_LANGUAGES) or re.search(r"\b(ES|DE|IT|JP|JA|KR)\b", g.get("version", "")):
        return False
    return True
games = [g for g in games if french_or_english(g)]
for g in games:
    if g.get("base") is None:
        g.pop("base", None)

order = {"GBA": 0, "GB": 1, "DS": 2}
games.sort(key=lambda g: (order[g["console"]], g["kind"] != "official", g["title"], g.get("version", "")))
out = os.path.join(os.path.dirname(__file__), "..", "App", "Library", "compat.json")
json.dump({"generatedFrom": "PokeDaisy fork, 3ds/core/pd_game.c and website/src/data/compat.json", "games": games},
          open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(len(games), "games ->", os.path.normpath(out))
