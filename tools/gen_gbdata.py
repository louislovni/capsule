#!/usr/bin/env python3
"""Generates Core/pkcore/pk_gbdata_gen.c: the data the Game Boy (generations 1
and 2) Pokemon screens need, which the GBA games keep in their ROM but the Game
Boy ones store in ways too varied to read back reliably.

Sources:
  - pret/pokered and pret/pokecrystal (https://github.com/pret): base stats,
    internal species order of Red/Blue/Yellow, item and landmark lists.
  - PokeAPI (https://github.com/PokeAPI/pokeapi, BSD 3-Clause): French names of
    species, moves, items and places.

Usage:
  python3 tools/gen_gbdata.py POKERED POKECRYSTAL POKEAPI_CSV_DIR Core/pkcore/pk_gbdata_gen.c
"""
import csv
import pathlib
import re
import sys
import unicodedata

FRENCH = "5"
ENGLISH = "9"

TYPE_IDS = {
    "NORMAL": 0, "FIGHTING": 1, "FLYING": 2, "POISON": 3, "GROUND": 4, "ROCK": 5, "BIRD": 6,
    "BUG": 7, "GHOST": 8, "STEEL": 9, "CURSE_TYPE": 19, "FIRE": 20, "WATER": 21, "GRASS": 22,
    "ELECTRIC": 23, "PSYCHIC_TYPE": 24, "ICE": 25, "DRAGON": 26, "DARK": 27,
}
GROWTH = {
    "GROWTH_MEDIUM_FAST": 0, "GROWTH_SLIGHTLY_FAST": 1, "GROWTH_SLIGHTLY_SLOW": 2,
    "GROWTH_MEDIUM_SLOW": 3, "GROWTH_FAST": 4, "GROWTH_SLOW": 5,
}
# percent = x * 255 / 100 (pokecrystal macros/data.asm)
GENDER = {
    "GENDER_F0": 0, "GENDER_F12_5": 12 * 255 // 100 + 1, "GENDER_F25": 25 * 255 // 100,
    "GENDER_F50": 50 * 255 // 100, "GENDER_F75": 75 * 255 // 100, "GENDER_F100": 100 * 255 // 100 - 1,
    "GENDER_UNKNOWN": 255,
}


# French names PokeAPI cannot match by their English Game Boy spelling.
ITEM_OVERRIDES = {
    "PARLYZ HEAL": "Anti-Para", "MAX ELIXER": "Max Élixir", "ELIXER": "Élixir", "X DEFEND": "Défense +",
    "X SPECIAL": "Spécial +", "ITEMFINDER": "Cherch'Objet", "BERRY": "Baie", "GOLD BERRY": "Baie Or",
    "MIRACLEBERRY": "Baie Miracle", "MYSTERYBERRY": "Baie Mystère", "PSNCUREBERRY": "Baie AntiPoison",
    "PRZCUREBERRY": "Baie AntiPara", "BURNT BERRY": "Baie Brûlure", "ICE BERRY": "Baie Gel",
    "BITTER BERRY": "Baie Amère", "MINT BERRY": "Baie Menthe", "PINK BOW": "Ruban Rose",
    "POLKADOT BOW": "Ruban à Pois", "STICK": "Bâton", "GS BALL": "GS Ball",
    "BLU APRICORN": "Noigrume Bleu", "YLW APRICORN": "Noigrume Jaune", "GRN APRICORN": "Noigrume Vert",
    "WHT APRICORN": "Noigrume Blanc", "BLK APRICORN": "Noigrume Noir", "PNK APRICORN": "Noigrume Rose",
}
PLACE_OVERRIDES = {
    "SPECIAL": None, "TIN TOWER": "Tour Carillon", "BATTLE TOWER": "Tour de Combat",
    "DRAGON'S DEN": "Antre du Dragon", "SILVER CAVE": "Mont Argenté", "UNDERGROUND": "Souterrain",
    "DIGLETT'S CAVE": "Cave Taupiqueur", "LAV RADIO TOWER": "Tour Radio de Lavanville",
    "VICTORY ROAD": "Route Victoire", "FAST SHIP": "Aquaria",
}


def read_csv(path):
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def norm(text):
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", text)


def c_string(text):
    if text is None:
        return "NULL"
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def include_list(path):
    out = []
    for line in path.read_text().splitlines():
        m = re.match(r'\s*INCLUDE "(data/pokemon/base_stats/[^"]+)"', line)
        if m:
            out.append(m.group(1))
    return out


def numbers(line):
    return [int(x) for x in re.findall(r"\b\d+\b", line.split(";")[0])]


def parse_gen1(red):
    base = {}
    names = include_list(red / "data/pokemon/base_stats.asm")
    # Mew is kept apart in Red and Blue.
    if "data/pokemon/base_stats/mew.asm" not in names:
        names.append("data/pokemon/base_stats/mew.asm")
    for dex, rel in enumerate(names, start=1):
        text = (red / rel).read_text().splitlines()
        db = [l for l in text if l.strip().startswith("db ")]
        stats = numbers(db[1])
        types = re.findall(r"[A-Z_]+", db[2].split(";")[0].replace("db", ""))
        growth = next(GROWTH[g] for g in GROWTH if any(g in l for l in text))
        assert len(stats) == 5, rel
        base[dex] = stats + [TYPE_IDS[types[0]], TYPE_IDS[types[1]], growth]
    assert len(base) == 151, len(base)

    dex_consts = {}
    n = 0
    for line in (red / "constants/pokedex_constants.asm").read_text().splitlines():
        m = re.match(r"\s*const (DEX_\w+)", line)
        if m:
            n += 1
            dex_consts[m.group(1)] = n
    order = []
    for line in (red / "data/pokemon/dex_order.asm").read_text().splitlines():
        m = re.match(r"\s*db (\w+)", line)
        if m:
            order.append(dex_consts.get(m.group(1), 0))
    assert len(order) == 190, len(order)
    return base, order


def parse_gen2(crystal):
    base = {}
    for dex, rel in enumerate(include_list(crystal / "data/pokemon/base_stats.asm"), start=1):
        text = (crystal / rel).read_text().splitlines()
        db = [l for l in text if l.strip().startswith("db ")]
        stats = numbers(db[1])
        types = re.findall(r"[A-Z_]+", db[2].split(";")[0].replace("db", ""))
        gender = next(GENDER[g] for g in sorted(GENDER, key=len, reverse=True) if any(re.search(r"\b" + g + r"\b", l) for l in text))
        growth = next(GROWTH[g] for g in GROWTH if any(g in l for l in text))
        assert len(stats) == 6, rel
        base[dex] = stats + [TYPE_IDS[types[0]], TYPE_IDS[types[1]], gender, growth]
    assert len(base) == 251, len(base)

    items = {}
    lines = (crystal / "data/items/names.asm").read_text().splitlines()
    index = 0
    for line in lines:
        m = re.match(r'\s*li "(.*)"', line)
        if m:
            index += 1
            items[index] = m.group(1)

    landmarks = []
    text = (crystal / "data/maps/landmarks.asm").read_text()
    labels = dict(re.findall(r'^(\w+Name):\s*db "([^"]*)"', text, re.M))
    for label in re.findall(r"^\s*landmark\s+-?\d+,\s*-?\d+,\s*(\w+)", text, re.M):
        name = labels.get(label)
        landmarks.append(name.replace("<BSP>", " ").rstrip("@").replace("#", "POKé") if name else None)
    return base, items, landmarks


def main(red, crystal, api, out):
    red, crystal, api = pathlib.Path(red), pathlib.Path(crystal), pathlib.Path(api)
    gen1, order = parse_gen1(red)
    gen2, items_en, landmarks_en = parse_gen2(crystal)

    species_fr = {int(r["pokemon_species_id"]): r["name"] for r in read_csv(api / "pokemon_species_names.csv")
                  if r["local_language_id"] == FRENCH}
    moves_fr = {int(r["move_id"]): r["name"] for r in read_csv(api / "move_names.csv")
                if r["local_language_id"] == FRENCH}

    item_names = read_csv(api / "item_names.csv")
    english_items = {}
    for r in item_names:
        if r["local_language_id"] == ENGLISH:
            english_items.setdefault(norm(r["name"]), r["item_id"])
    french_items = {r["item_id"]: r["name"] for r in item_names if r["local_language_id"] == FRENCH}
    items_fr = {}
    missing_items = []
    for index, name in items_en.items():
        if name in ("TERU-SAMA", "?", ""):
            continue
        key = norm(name.replace("#", "POKé"))
        m = re.match(r"(TM|HM)(\d\d)", name)
        if name in ITEM_OVERRIDES:
            items_fr[index] = ITEM_OVERRIDES[name]
        elif m:
            items_fr[index] = ("CT" if m.group(1) == "TM" else "CS") + m.group(2)
        elif key in english_items and english_items[key] in french_items:
            items_fr[index] = french_items[english_items[key]]
        else:
            items_fr[index] = name.title().replace("Poké", "Poké")
            missing_items.append(name)

    locations = {r["identifier"]: r["id"] for r in read_csv(api / "locations.csv")}
    location_fr = {r["location_id"]: r["name"] for r in read_csv(api / "location_names.csv")
                   if r["local_language_id"] == FRENCH}
    landmarks_fr = []
    missing_places = []
    for name in landmarks_en:
        if not name or name in PLACE_OVERRIDES:
            landmarks_fr.append(PLACE_OVERRIDES.get(name) if name else None)
            continue
        ident = re.sub(r"[^a-z0-9]+", "-", name.lower().replace("poké", "poke")).strip("-")
        candidates = [ident, ident + "-area", "johto-" + ident, "kanto-" + ident]
        found = next((location_fr[locations[c]] for c in candidates if c in locations and locations[c] in location_fr), None)
        if not found:
            missing_places.append(name)
            found = name.title()
        landmarks_fr.append(found)

    L = ["/* GENERATED by tools/gen_gbdata.py. Do not edit by hand.",
         " * Base stats and orders: pret/pokered and pret/pokecrystal disassemblies.",
         " * French names: PokeAPI (BSD 3-Clause), see NOTICE. */",
         '#include "pkcore.h"', ""]

    L.append("const char* const pk_gb_species_names[252] = {\n\tNULL,")
    L += ["\t%s, /* %d */" % (c_string(species_fr[d]), d) for d in range(1, 252)]
    L.append("};\n")
    L.append("const char* const pk_gb_move_names[252] = {\n\tNULL,")
    L += ["\t%s, /* %d */" % (c_string(moves_fr.get(m)), m) for m in range(1, 252)]
    L.append("};\n")
    L.append("const char* const pk_gb_item_names[256] = {\n\tNULL,")
    L += ["\t%s, /* 0x%02X */" % (c_string(items_fr.get(i)), i) for i in range(1, 256)]
    L.append("};\n")
    L.append("const char* const pk_gb_landmark_names[%d] = {" % len(landmarks_fr))
    L += ["\t%s, /* %d */" % (c_string(n), i) for i, n in enumerate(landmarks_fr)]
    L.append("};\nconst size_t pk_gb_landmark_count = %d;\n" % len(landmarks_fr))
    L.append("const uint8_t pk_gb1_index_to_dex[256] = {\n\t0,")
    for i in range(1, 256):
        L.append("\t%d, /* 0x%02X */" % (order[i - 1] if i <= len(order) else 0, i))
    L.append("};\n")
    L.append("/* HP, Atk, Def, Spe, Special, type 1, type 2, growth rate */")
    L.append("const uint8_t pk_gb1_base[152][8] = {\n\t{ 0 },")
    L += ["\t{ %s }, /* %d */" % (", ".join(map(str, gen1[d])), d) for d in range(1, 152)]
    L.append("};\n")
    L.append("/* HP, Atk, Def, Spe, SpA, SpD, type 1, type 2, gender ratio, growth rate */")
    L.append("const uint8_t pk_gb2_base[252][10] = {\n\t{ 0 },")
    L += ["\t{ %s }, /* %d */" % (", ".join(map(str, gen2[d])), d) for d in range(1, 252)]
    L.append("};\n")
    pathlib.Path(out).write_text("\n".join(L), encoding="utf-8")
    print("items without a French name:", missing_items)
    print("places without a French name:", missing_places)


if __name__ == "__main__":
    main(*sys.argv[1:5])
