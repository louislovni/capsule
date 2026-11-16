/* Derived Pokemon information and the ROM tables it needs. GPL v3.
 *
 * Formulas and table layouts follow the pret decompilations (pokeemerald,
 * pokefirered). Tables are located by content, so the code works for every
 * language and for most hacks that keep the original layout.
 */
#include "pkcore.h"

#include <string.h>

#define ROM_BASE 0x08000000u

static uint16_t rd16(const uint8_t* p) {
	return (uint16_t) (p[0] | (p[1] << 8));
}

static uint32_t rd32(const uint8_t* p) {
	return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

/* ---------- Experience ---------- */

static long long cube(long long n) {
	return n * n * n;
}

uint32_t pk_exp_for_level(uint8_t growthRate, unsigned level) {
	if (level <= 1) {
		return 0;
	}
	if (level > 100) {
		level = 100;
	}
	long long n = level;
	long long exp;
	switch (growthRate) {
	case 1: /* erratic */
		if (n <= 50) {
			exp = cube(n) * (100 - n) / 50;
		} else if (n <= 68) {
			exp = cube(n) * (150 - n) / 100;
		} else if (n <= 98) {
			exp = cube(n) * ((1911 - 10 * n) / 3) / 500;
		} else {
			exp = cube(n) * (160 - n) / 100;
		}
		break;
	case 2: /* fluctuating */
		if (n <= 15) {
			exp = cube(n) * ((n + 1) / 3 + 24) / 50;
		} else if (n <= 36) {
			exp = cube(n) * (n + 14) / 50;
		} else {
			exp = cube(n) * (n / 2 + 32) / 50;
		}
		break;
	case 3: /* medium slow */
		exp = 6 * cube(n) / 5 - 15 * n * n + 100 * n - 140;
		break;
	case 4: /* fast */
		exp = 4 * cube(n) / 5;
		break;
	case 5: /* slow */
		exp = 5 * cube(n) / 4;
		break;
	default: /* medium fast */
		exp = cube(n);
		break;
	}
	return exp < 0 ? 0 : (uint32_t) exp;
}

uint8_t pk_level_for_exp(uint8_t growthRate, uint32_t exp) {
	unsigned level = 1;
	while (level < 100 && pk_exp_for_level(growthRate, level + 1) <= exp) {
		++level;
	}
	return (uint8_t) level;
}

/* ---------- Stats ---------- */

void pk_nature_effect(unsigned nature, int* raised, int* lowered) {
	int up = (int) (nature % 25) / 5;
	int down = (int) (nature % 25) % 5;
	if (up == down) {
		up = -1;
		down = -1;
	}
	if (raised) {
		*raised = up;
	}
	if (lowered) {
		*lowered = down;
	}
}

#define SPECIES_SHEDINJA 303

void pk_calc_stats(const PKBaseStats* base, const uint8_t ivs[6], const uint8_t evs[6], unsigned level,
                   unsigned nature, uint16_t species, uint16_t out[6]) {
	if (!base || !ivs || !evs || !out) {
		return;
	}
	if (level < 1) {
		level = 1;
	}
	if (level > 100) {
		level = 100;
	}
	int raised, lowered;
	pk_nature_effect(nature, &raised, &lowered);
	for (int i = 0; i < 6; ++i) {
		unsigned core = (2u * base->baseStats[i] + ivs[i] + evs[i] / 4u) * level / 100u;
		if (i == 0) {
			out[0] = (uint16_t) (species == SPECIES_SHEDINJA ? 1 : core + level + 10);
			continue;
		}
		unsigned value = core + 5;
		if (i - 1 == raised) {
			value = value * 110 / 100;
		} else if (i - 1 == lowered) {
			value = value * 90 / 100;
		}
		out[i] = (uint16_t) value;
	}
}

int pk_gender(uint32_t personality, uint8_t genderRatio) {
	if (genderRatio == 255) {
		return 2;
	}
	if (genderRatio == 254) {
		return 1;
	}
	if (genderRatio == 0) {
		return 0;
	}
	return (personality & 0xFF) < genderRatio ? 1 : 0;
}

unsigned pk_ribbon_count(uint32_t ribbons) {
	unsigned count = 0;
	/* Five contest categories, 3 bits each: the rank reached (0..4). */
	for (int i = 0; i < 5; ++i) {
		count += (ribbons >> (3 * i)) & 0x07;
	}
	/* Champion, Winning, Victory, Artist, Effort, then 7 special ribbons. */
	for (int bit = 15; bit <= 26; ++bit) {
		count += (ribbons >> bit) & 1;
	}
	return count;
}

/* ---------- Locating tables ---------- */

static bool in_rom(uint32_t pointer, size_t size) {
	return pointer >= ROM_BASE && pointer - ROM_BASE < size;
}

/* A short, terminated string made of letters, digits and ordinary punctuation. */
static bool plausible_label(const uint8_t* rom, size_t size, size_t offset, size_t maxLength) {
	if (offset >= size) {
		return false;
	}
	uint8_t first = rom[offset];
	bool okFirst = (first >= 0xA1 && first <= 0xAA) || (first >= 0xBB && first <= 0xEE) ||
	               (first >= 0x01 && first <= 0x2B) || (first >= 0xF1 && first <= 0xF6);
	if (!okFirst) {
		return false;
	}
	for (size_t i = 1; i < maxLength && offset + i < size; ++i) {
		uint8_t c = rom[offset + i];
		if (c == 0xFF) {
			return true;
		}
		if (c >= 0xF7) { /* control codes: line breaks, colours, placeholders */
			return false;
		}
	}
	return false;
}

long pk_rom_find_ability_names(const uint8_t* rom, size_t size) {
	/* Entry 0 is "-------". */
	static const uint8_t first[8] = { 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xFF };
	const unsigned entries = 78;
	if (!rom || size < PK_ABILITY_NAME_STRIDE * entries) {
		return -1;
	}
	for (size_t off = 0; off + PK_ABILITY_NAME_STRIDE * entries <= size; ++off) {
		if (rom[off] != 0xAE || memcmp(rom + off, first, sizeof(first)) != 0) {
			continue;
		}
		bool ok = true;
		for (unsigned i = 1; i < entries && ok; ++i) {
			ok = plausible_label(rom, size, off + i * PK_ABILITY_NAME_STRIDE, PK_ABILITY_NAME_STRIDE);
		}
		if (ok) {
			return (long) off;
		}
	}
	return -1;
}

long pk_rom_find_items(const uint8_t* rom, size_t size) {
	/* Entry 0 is named "????????" and every entry stores its own index at +14. */
	static const uint8_t first[9] = { 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xFF };
	const unsigned checked = 40;
	if (!rom || size < PK_ITEM_STRIDE * checked) {
		return -1;
	}
	for (size_t off = 0; off + PK_ITEM_STRIDE * checked <= size; off += 4) {
		if (rom[off] != 0xAC || memcmp(rom + off, first, sizeof(first)) != 0 || rd16(rom + off + 14) != 0) {
			continue;
		}
		bool ok = true;
		for (unsigned i = 1; i < checked && ok; ++i) {
			size_t entry = off + i * PK_ITEM_STRIDE;
			ok = rd16(rom + entry + 14) == i && plausible_label(rom, size, entry, PK_ITEM_NAME_LENGTH);
		}
		if (ok) {
			return (long) off;
		}
	}
	return -1;
}

long pk_rom_find_base_stats(const uint8_t* rom, size_t size) {
	/* Entry 0 is empty, entry 1 is Bulbasaur: 45/49/49/45/65/65, Grass/Poison. */
	static const uint8_t bulbasaur[8] = { 45, 49, 49, 45, 65, 65, 12, 3 };
	if (!rom || size < 28 * 2) {
		return -1;
	}
	for (size_t off = 0; off + 28 * 2 <= size; off += 4) {
		if (rom[off + 28] != 45 || memcmp(rom + off + 28, bulbasaur, sizeof(bulbasaur)) != 0) {
			continue;
		}
		bool empty = true;
		for (int i = 0; i < 28 && empty; ++i) {
			empty = rom[off + i] == 0;
		}
		if (empty) {
			return (long) off;
		}
	}
	return -1;
}

long pk_rom_find_national_dex(const uint8_t* rom, size_t size) {
	/* Species 1..251 have the same internal and national numbers. */
	const unsigned run = 251;
	if (!rom || size < run * 2) {
		return -1;
	}
	for (size_t off = 0; off + run * 2 <= size; off += 2) {
		if (rom[off] != 1 || rom[off + 1] != 0) {
			continue;
		}
		bool ok = true;
		for (unsigned i = 1; i < run && ok; ++i) {
			ok = rd16(rom + off + i * 2) == i + 1;
		}
		if (ok) {
			return (long) off;
		}
	}
	return -1;
}

/* Ruby, Sapphire, Emerald: {u8 x, y, width, height; const u8* name} per location. */
static bool region_map_entry(const uint8_t* rom, size_t size, size_t off) {
	if (off + 8 > size) {
		return false;
	}
	uint8_t x = rom[off], y = rom[off + 1], w = rom[off + 2], h = rom[off + 3];
	uint32_t name = rd32(rom + off + 4);
	if (x >= 32 || y >= 24 || w == 0 || h == 0 || w > 32 || h > 24 || !in_rom(name, size)) {
		return false;
	}
	return plausible_label(rom, size, name - ROM_BASE, 24);
}

static bool name_pointer(const uint8_t* rom, size_t size, size_t off) {
	if (off + 4 > size) {
		return false;
	}
	uint32_t name = rd32(rom + off);
	return in_rom(name, size) && plausible_label(rom, size, name - ROM_BASE, 24);
}

long pk_rom_find_location_names(const uint8_t* rom, size_t size, int* kind, unsigned* count) {
	if (kind) {
		*kind = PK_MAPSEC_NONE;
	}
	if (count) {
		*count = 0;
	}
	if (!rom) {
		return -1;
	}
	/* Region map table: at least the 88 Hoenn locations in a row. */
	for (size_t off = 0; off + 8 * 88 <= size; off += 4) {
		if (!region_map_entry(rom, size, off)) {
			continue;
		}
		unsigned n = 1;
		while (n < 256 && region_map_entry(rom, size, off + n * 8)) {
			++n;
		}
		if (n >= 88) {
			if (kind) {
				*kind = PK_MAPSEC_REGION_MAP;
			}
			if (count) {
				*count = n;
			}
			return (long) off;
		}
	}
	/* FireRed / LeafGreen: a list of pointers to the Kanto location names. */
	for (size_t off = 0; off + 4 * 100 <= size; off += 4) {
		if (!name_pointer(rom, size, off)) {
			continue;
		}
		unsigned n = 1;
		while (n < 256 && name_pointer(rom, size, off + n * 4)) {
			++n;
		}
		if (n >= 100 && n <= 120) {
			if (kind) {
				*kind = PK_MAPSEC_NAME_LIST;
			}
			if (count) {
				*count = n;
			}
			return (long) off;
		}
		off += (size_t) (n - 1) * 4; /* skip the rest of this run */
	}
	return -1;
}

/* ---------- Reading tables ---------- */

bool pk_rom_base_stats(const uint8_t* rom, size_t size, long table, uint16_t species, PKBaseStats* out) {
	if (!rom || !out || table < 0 || species == 0) {
		return false;
	}
	size_t off = (size_t) table + (size_t) species * 28;
	if (off + 28 > size) {
		return false;
	}
	const uint8_t* e = rom + off;
	memset(out, 0, sizeof(*out));
	memcpy(out->baseStats, e, 6);
	out->type1 = e[6];
	out->type2 = e[7];
	out->catchRate = e[8];
	out->expYield = e[9];
	out->item1 = rd16(e + 12);
	out->item2 = rd16(e + 14);
	out->genderRatio = e[16];
	out->eggCycles = e[17];
	out->baseFriendship = e[18];
	out->growthRate = e[19];
	out->eggGroup1 = e[20];
	out->eggGroup2 = e[21];
	out->ability1 = e[22];
	out->ability2 = e[23];
	/* An all-zero entry is a placeholder, not a real species. */
	return out->baseStats[0] != 0 && out->growthRate <= 5;
}

unsigned pk_rom_national_dex(const uint8_t* rom, size_t size, long table, uint16_t species) {
	if (!rom || table < 0 || species == 0) {
		return 0;
	}
	size_t off = (size_t) table + ((size_t) species - 1) * 2;
	if (off + 2 > size) {
		return 0;
	}
	unsigned value = rd16(rom + off);
	return value <= 386 ? value : 0;
}

/* Special values of the met location byte. */
#define METLOC_SPECIAL_EGG 0xFD
#define METLOC_IN_GAME_TRADE 0xFE
#define METLOC_FATEFUL_ENCOUNTER 0xFF
#define KANTO_FIRST_LOCATION 0x58

void pk_rom_location_name(const uint8_t* rom, size_t size, long table, int kind, unsigned count,
                          unsigned location, char* out, size_t outSize) {
	if (!out || outSize == 0) {
		return;
	}
	out[0] = '\0';
	if (!rom || table < 0 || location >= METLOC_SPECIAL_EGG) {
		return;
	}
	size_t pointerAt;
	if (kind == PK_MAPSEC_REGION_MAP) {
		if (location >= count) {
			return;
		}
		pointerAt = (size_t) table + (size_t) location * 8 + 4;
	} else if (kind == PK_MAPSEC_NAME_LIST) {
		if (location < KANTO_FIRST_LOCATION || location - KANTO_FIRST_LOCATION >= count) {
			return;
		}
		pointerAt = (size_t) table + (size_t) (location - KANTO_FIRST_LOCATION) * 4;
	} else {
		return;
	}
	if (pointerAt + 4 > size) {
		return;
	}
	uint32_t name = rd32(rom + pointerAt);
	if (!in_rom(name, size)) {
		return;
	}
	pk_text_decode(rom + (name - ROM_BASE), 24, out, outSize);
}
