/* Live-memory helpers: per-game addresses, party scan, ROM name tables. GPL v3. */
#include "pkcore.h"

#include <string.h>

const PKProfile* pk_profile_find(const char* code4, uint8_t revision) {
	if (!code4) {
		return NULL;
	}
	const PKProfile* sameCode = NULL;
	for (size_t i = 0; i < pk_profile_count; ++i) {
		const PKProfile* p = &pk_profiles[i];
		if (memcmp(p->code, code4, 4) != 0) {
			continue;
		}
		if (p->revision == revision) {
			return p;
		}
		if (!sameCode) {
			sameCode = p;
		}
	}
	return sameCode;
}

static bool plausible_party_mon(const uint8_t* raw) {
	PKMon mon;
	if (!pk_mon_decode(raw, PK_PARTY_MON_SIZE, &mon)) {
		return false;
	}
	if (mon.personality == 0 && mon.otId == 0) {
		return false;
	}
	if (mon.level < 1 || mon.level > 100) {
		return false;
	}
	if (mon.maxHp == 0 || mon.maxHp > 999 || mon.hp > mon.maxHp) {
		return false;
	}
	if (mon.attack == 0 || mon.attack > 999 || mon.speed == 0 || mon.speed > 999) {
		return false;
	}
	return true;
}

long pk_scan_party(const uint8_t* ram, size_t size, int* countOut) {
	if (countOut) {
		*countOut = 0;
	}
	if (!ram || size < PK_PARTY_MON_SIZE) {
		return -1;
	}
	for (size_t off = 0; off + PK_PARTY_MON_SIZE <= size; off += 4) {
		/* Cheap reject before the full decode: the "has species" flag. */
		if (!(ram[off + 19] & 0x02)) {
			continue;
		}
		if (!plausible_party_mon(ram + off)) {
			continue;
		}
		int count = 1;
		while (count < 6 && off + (size_t) (count + 1) * PK_PARTY_MON_SIZE <= size &&
		       plausible_party_mon(ram + off + (size_t) count * PK_PARTY_MON_SIZE)) {
			++count;
		}
		if (countOut) {
			*countOut = count;
		}
		return (long) off;
	}
	return -1;
}

/* A table entry is plausible when it is terminated inside its stride and
 * starts with a letter, digit or one of the few symbols names begin with. */
static bool plausible_name(const uint8_t* entry, size_t stride) {
	uint8_t first = entry[0];
	bool okFirst = (first >= 0xA1 && first <= 0xAE) || (first >= 0xBB && first <= 0xEE) || (first >= 0x01 && first <= 0x2B);
	if (!okFirst) {
		return false;
	}
	for (size_t i = 1; i < stride; ++i) {
		if (entry[i] == 0xFF) {
			return true;
		}
	}
	return false;
}

static long find_table(const uint8_t* rom, size_t size, const uint8_t* first, size_t firstLen, size_t stride,
                       unsigned entries) {
	if (!rom || size < (size_t) stride * entries) {
		return -1;
	}
	size_t last = size - (size_t) stride * entries;
	for (size_t off = 0; off <= last; ++off) {
		if (rom[off] != first[0] || memcmp(rom + off, first, firstLen) != 0) {
			continue;
		}
		bool ok = true;
		for (unsigned i = 1; i < entries; ++i) {
			if (!plausible_name(rom + off + (size_t) i * stride, stride)) {
				ok = false;
				break;
			}
		}
		if (ok) {
			return (long) off;
		}
	}
	return -1;
}

long pk_rom_find_species_names(const uint8_t* rom, size_t size) {
	/* Entry 0 is "??????????" in every Western release. */
	static const uint8_t first[11] = { 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xAC, 0xFF };
	return find_table(rom, size, first, sizeof(first), PK_SPECIES_NAME_STRIDE, 412);
}

long pk_rom_find_move_names(const uint8_t* rom, size_t size) {
	/* Entry 0 is "-" padded with zeroes. */
	static const uint8_t first[13] = { 0xAE, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	return find_table(rom, size, first, sizeof(first), PK_MOVE_NAME_STRIDE, 355);
}

void pk_rom_table_name(const uint8_t* rom, size_t size, long table, size_t stride, unsigned index, char* out,
                       size_t outSize) {
	if (out && outSize) {
		out[0] = '\0';
	}
	if (!rom || table < 0 || stride == 0) {
		return;
	}
	size_t off = (size_t) table + (size_t) index * stride;
	if (off + stride > size) {
		return;
	}
	pk_text_decode(rom + off, stride, out, outSize);
}
