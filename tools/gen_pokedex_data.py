#!/usr/bin/env python3
"""Builds the Pokédex data of species 1-649 (French names where PokeAPI has them):
height, weight, category, abilities, evolutions and where to catch them in the
generation 1-5 games. Source: PokeAPI's CSV files (BSD 3-Clause), https://github.com/PokeAPI/pokeapi

    python3 tools/gen_pokedex_data.py /path/to/pokeapi/data/v2/csv

writes docs/pokedex-data.json (the web page) and App/Pokedex/pokedex-data.json (the app).
"""
import csv
import json
import os
import sys
from collections import defaultdict

MAX = 649
FR, EN = 5, 9
VERSIONS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 21, 22]
METHODS = {
    "walk": "Herbes ou grotte", "old-rod": "Canne", "good-rod": "Super Canne", "super-rod": "Méga Canne",
    "surf": "Surf", "rock-smash": "Éclate-Roc", "headbutt": "Coup d'Boule", "headbutt-low": "Coup d'Boule",
    "headbutt-normal": "Coup d'Boule", "headbutt-high": "Coup d'Boule", "dark-grass": "Herbes sombres",
    "grass-spots": "Herbes mouvantes", "cave-spots": "Nuage de poussière", "bridge-spots": "Ombre de pont",
    "super-rod-spots": "Pêche (remous)", "surf-spots": "Surf (remous)", "yellow-flowers": "Fleurs jaunes",
    "purple-flowers": "Fleurs violettes", "red-flowers": "Fleurs rouges", "rough-terrain": "Terrain accidenté",
    "gift": "Cadeau", "gift-egg": "Œuf offert", "static": "Rencontre unique", "pokeflute": "Pokéflûte",
    "squirt-bottle": "Carapuce à O", "wailmer-pail": "Seau Wailmer", "seaweed": "Algues",
    "roaming-grass": "Errant", "roaming-water": "Errant (sur l'eau)", "devon-scope": "Devon Scope",
    "feebas-tile-fishing": "Pêche (case précise)", "npc-trade": "Échange avec un PNJ",
}


def rows(base, name):
    with open(os.path.join(base, name + ".csv"), newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def names(base, name, key, field="name"):
    """id -> French name, English when PokeAPI has no French one."""
    out, en = {}, {}
    for r in rows(base, name):
        lang = int(r["local_language_id"])
        if lang == FR and r[field]:
            out[int(r[key])] = r[field]
        elif lang == EN and r[field]:
            en[int(r[key])] = r[field]
    for k, v in en.items():
        out.setdefault(k, v)
    return out


def main(base):
    species_rows = {int(r["id"]): r for r in rows(base, "pokemon_species") if int(r["id"]) <= MAX}
    species_names = names(base, "pokemon_species_names", "pokemon_species_id")
    genus = names(base, "pokemon_species_names", "pokemon_species_id", "genus")
    pokemon = {int(r["id"]): r for r in rows(base, "pokemon") if int(r["id"]) <= MAX}
    ability_names = names(base, "ability_names", "ability_id")
    item_names = names(base, "item_names", "item_id")
    location_names = names(base, "location_names", "location_id")
    move_names = names(base, "move_names", "move_id")
    type_names = names(base, "type_names", "type_id")
    version_names = names(base, "version_names", "version_id")

    abilities = defaultdict(list)
    for r in rows(base, "pokemon_abilities"):
        pid = int(r["pokemon_id"])
        aid = int(r["ability_id"])
        # Generation 1-5 abilities only (ids up to 164); hidden ones came with generation 5.
        if pid <= MAX and aid <= 164:
            abilities[pid].append((int(r["slot"]), ability_names.get(aid, "?"), r["is_hidden"] == "1"))

    # ---- Evolutions: how each species evolves from the one before it.
    def method(r):
        trig = int(r["evolution_trigger_id"])
        parts = []
        lvl = r["minimum_level"]
        if trig == 1:
            parts.append(f"Niveau {lvl}" if lvl else "Monter d'un niveau")
        elif trig == 2:
            parts.append("Échange")
        elif trig == 3:
            parts.append(item_names.get(int(r["trigger_item_id"]), "objet"))
        elif trig == 4:
            parts.append("Apparaît au niveau 20 de Ningale (place libre et Poké Ball)")
        else:
            return None
        if r["held_item_id"]:
            parts.append(("en tenant " if trig == 2 else "en tenant ") + item_names.get(int(r["held_item_id"]), "objet"))
        if r["trade_species_id"]:
            parts.append("contre " + species_names.get(int(r["trade_species_id"]), "?"))
        if r["minimum_happiness"]:
            parts.append("avec beaucoup d'amitié")
        if r["minimum_beauty"]:
            parts.append("avec beaucoup de beauté")
        if r["time_of_day"] == "day":
            parts.append("de jour")
        elif r["time_of_day"] == "night":
            parts.append("de nuit")
        if r["gender_id"]:
            parts.append("(femelle)" if r["gender_id"] == "1" else "(mâle)")
        if r["known_move_id"]:
            parts.append("en connaissant " + move_names.get(int(r["known_move_id"]), "?"))
        if r["known_move_type_id"]:
            parts.append("avec une attaque " + type_names.get(int(r["known_move_type_id"]), "?"))
        if r["location_id"]:
            parts.append("à " + location_names.get(int(r["location_id"]), "?"))
        if r["party_species_id"]:
            parts.append("avec " + species_names.get(int(r["party_species_id"]), "?") + " dans l'équipe")
        if r["party_type_id"]:
            parts.append("avec un Pokémon " + type_names.get(int(r["party_type_id"]), "?") + " dans l'équipe")
        stats = r["relative_physical_stats"]
        if stats == "1":
            parts.append("si Attaque > Défense")
        elif stats == "-1":
            parts.append("si Attaque < Défense")
        elif stats == "0":
            parts.append("si Attaque = Défense")
        if r["needs_overworld_rain"] == "1":
            parts.append("sous la pluie")
        if r["turn_upside_down"] == "1":
            parts.append("console retournée")
        return " ".join(parts)

    how = defaultdict(list)
    for r in rows(base, "pokemon_evolution"):
        sid = int(r["evolved_species_id"])
        if sid > MAX:
            continue
        vg = r["version_group_id"]
        if vg and int(vg) > 14:  # games after Black 2 / White 2
            continue
        if r["trigger_item_id"] and int(r["trigger_item_id"]) > 600:
            continue
        text = method(r)
        if text and text not in how[sid]:
            how[sid].append(text)

    # ---- Where to catch them, per game.
    slots = {int(r["id"]): int(r["encounter_method_id"]) for r in rows(base, "encounter_slots")}
    method_ids = {int(r["id"]): r["identifier"] for r in rows(base, "encounter_methods")}
    area_location = {int(r["id"]): int(r["location_id"]) for r in rows(base, "location_areas")}
    found = defaultdict(lambda: defaultdict(dict))  # species -> version -> (location, method) -> [min, max]
    for r in rows(base, "encounters"):
        pid, vid = int(r["pokemon_id"]), int(r["version_id"])
        if pid > MAX or vid not in VERSIONS:
            continue
        loc = location_names.get(area_location.get(int(r["location_area_id"]), 0), "?")
        meth = METHODS.get(method_ids.get(slots.get(int(r["encounter_slot_id"]), 0), ""), "Autre")
        key = (loc, meth)
        lo, hi = int(r["min_level"]), int(r["max_level"])
        if key in found[pid][vid]:
            a, b = found[pid][vid][key]
            found[pid][vid][key] = [min(a, lo), max(b, hi)]
        else:
            found[pid][vid][key] = [lo, hi]

    out = []
    for sid in range(1, MAX + 1):
        s, p = species_rows[sid], pokemon[sid]
        prev = int(s["evolves_from_species_id"]) if s["evolves_from_species_id"] else 0
        item = {
            "h": int(p["height"]),  # decimetres
            "w": int(p["weight"]),  # hectograms
            "c": genus.get(sid, ""),
            "a": [[name, 1] if hidden else name for _, name, hidden in sorted(abilities[sid])],
            "chain": int(s["evolution_chain_id"]),
        }
        if prev:
            item["pre"] = prev
            item["how"] = " ou ".join(how.get(sid, [])) or "?"
        where = {}
        for vid in VERSIONS:
            if vid in found[sid]:
                places = sorted(found[sid][vid].items(), key=lambda kv: (kv[0][0], kv[0][1]))
                where[str(vid)] = [[loc, meth, lo, hi] for (loc, meth), (lo, hi) in places]
        if where:
            item["where"] = where
        out.append(item)

    data = {
        "source": "PokeAPI (BSD 3-Clause)",
        "versions": {str(v): version_names.get(v, str(v)) for v in VERSIONS},
        "species": out,
    }
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    for path in ("docs/pokedex-data.json", "App/Pokedex/pokedex-data.json"):
        with open(os.path.join(root, path), "w", encoding="utf-8") as f:
            f.write(text)
    print(f"{len(out)} species, {len(text) // 1024} KiB")


if __name__ == "__main__":
    main(sys.argv[1])
