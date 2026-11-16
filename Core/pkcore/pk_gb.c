/* Pokemon of the Game Boy games (Red, Blue, Yellow, Gold, Silver, Crystal). GPL v3.
 *
 * Structures, save layout and formulas follow the pret disassemblies
 * (pokered, pokecrystal). Numbers in these games are big-endian.
 */
#include "pkcore.h"

#include <stdlib.h>
#include <string.h>

static uint16_t be16(const uint8_t* p) {
	return (uint16_t) ((p[0] << 8) | p[1]);
}

static uint32_t be24(const uint8_t* p) {
	return ((uint32_t) p[0] << 16) | ((uint32_t) p[1] << 8) | p[2];
}

/* ---------- Text ---------- */

static const char* gb_char(uint8_t c, char scratch[2]) {
	if (c >= 0x80 && c <= 0x99) {
		scratch[0] = (char) ('A' + (c - 0x80));
		return scratch;
	}
	if (c >= 0xA0 && c <= 0xB9) {
		scratch[0] = (char) ('a' + (c - 0xA0));
		return scratch;
	}
	if (c >= 0xF6) {
		scratch[0] = (char) ('0' + (c - 0xF6));
		return scratch;
	}
	switch (c) {
	case 0x7F: return " ";
	/* accented letters of the French and German releases */
	case 0xBA: return "à";
	case 0xBB: return "è";
	case 0xBC: return "é";
	case 0xBD: return "ù";
	case 0xBF: return "ç";
	case 0xC0: return "Ä";
	case 0xC1: return "Ö";
	case 0xC2: return "Ü";
	case 0xC3: return "ä";
	case 0xC4: return "ö";
	case 0xC5: return "ü";
	case 0xC6: return "ë";
	case 0xC7: return "ï";
	case 0xC8: return "â";
	case 0xC9: return "ô";
	case 0xCA: return "û";
	case 0xCB: return "ê";
	case 0xCC: return "î";
	case 0x9A: return "(";
	case 0x9B: return ")";
	case 0x9C: return ":";
	case 0x9D: return ";";
	case 0x9E: return "[";
	case 0x9F: return "]";
	case 0xE0: return "'";
	case 0xE1: return "Pk";
	case 0xE2: return "Mn";
	case 0xE3: return "-";
	case 0xE6: return "?";
	case 0xE7: return "!";
	case 0xE8: return ".";
	case 0xE9: return "&";
	case 0xEA: return "é";
	case 0xEF: return "♂";
	case 0xF0: return "¥";
	case 0xF1: return "×";
	case 0xF2: return ".";
	case 0xF3: return "/";
	case 0xF4: return ",";
	case 0xF5: return "♀";
	default: return NULL;
	}
}

size_t pk_gb_text_decode(const uint8_t* in, size_t maxLen, char* out, size_t outSize) {
	size_t n = 0;
	if (!out || outSize == 0) {
		return 0;
	}
	for (size_t i = 0; in && i < maxLen; ++i) {
		uint8_t c = in[i];
		if (c == 0x50 || c == 0x00) {
			break;
		}
		char scratch[2] = { 0, 0 };
		const char* s = gb_char(c, scratch);
		if (!s) {
			s = "?";
		}
		size_t len = strlen(s);
		if (n + len + 1 > outSize) {
			break;
		}
		memcpy(out + n, s, len);
		n += len;
	}
	out[n] = '\0';
	return n;
}

_Static_assert(PK_GB1_BLOB == PK_GB1_BOX_MON + 2 * PK_GB_NAME_LENGTH + 1, "blob size");
_Static_assert(PK_GB2_BLOB == PK_GB2_BOX_MON + 2 * PK_GB_NAME_LENGTH + 1, "blob size");

/* ---------- Names ---------- */

const char* pk_gb_species_name(unsigned dex) {
	return dex >= 1 && dex <= 251 ? pk_gb_species_names[dex] : NULL;
}

const char* pk_gb_move_name(unsigned move) {
	return move >= 1 && move <= 251 ? pk_gb_move_names[move] : NULL;
}

const char* pk_gb_item_name(unsigned item) {
	return item >= 1 && item <= 255 ? pk_gb_item_names[item] : NULL;
}

const char* pk_gb_landmark_name(unsigned landmark) {
	return landmark >= 1 && landmark < pk_gb_landmark_count ? pk_gb_landmark_names[landmark] : NULL;
}

/* ---------- Species data ---------- */

static unsigned dex_of(int generation, uint8_t species) {
	if (generation == 1) {
		return pk_gb1_index_to_dex[species];
	}
	return species >= 1 && species <= 251 ? species : 0;
}

bool pk_gb_base_stats(int generation, unsigned dex, uint8_t stats[6], uint8_t* type1, uint8_t* type2,
                      uint8_t* genderRatio, uint8_t* growthRate) {
	uint8_t s[6], t1, t2, gender, growth;
	if (generation == 1) {
		if (dex < 1 || dex > 151) {
			return false;
		}
		const uint8_t* b = pk_gb1_base[dex];
		memcpy(s, b, 5);
		s[5] = b[4];
		t1 = b[5];
		t2 = b[6];
		growth = b[7];
		gender = 255;
	} else {
		if (dex < 1 || dex > 251) {
			return false;
		}
		const uint8_t* b = pk_gb2_base[dex];
		memcpy(s, b, 6);
		t1 = b[6];
		t2 = b[7];
		gender = b[8];
		growth = b[9];
	}
	if (stats) {
		memcpy(stats, s, 6);
	}
	if (type1) {
		*type1 = t1;
	}
	if (type2) {
		*type2 = t2;
	}
	if (genderRatio) {
		*genderRatio = gender;
	}
	if (growthRate) {
		*growthRate = growth;
	}
	return true;
}

/* Smallest n with n * n >= value, at most 255, as the games compute it. */
static unsigned ceil_sqrt(unsigned value) {
	unsigned n = 0;
	while (n < 255 && n * n < value) {
		++n;
	}
	return n;
}

void pk_gb_calc_stats(int generation, unsigned dex, const uint8_t dvs[5], const uint16_t statExp[5], unsigned level,
                      uint16_t out[6]) {
	uint8_t base[6];
	memset(out, 0, 6 * sizeof(uint16_t));
	if (!pk_gb_base_stats(generation, dex, base, NULL, NULL, NULL, NULL)) {
		return;
	}
	if (level < 1) {
		level = 1;
	}
	if (level > 100) {
		level = 100;
	}
	/* SpA and SpD both use the Special DV and Special stat experience. */
	static const int source[6] = { 0, 1, 2, 3, 4, 4 };
	for (int i = 0; i < 6; ++i) {
		unsigned dv = dvs[source[i]];
		unsigned term = ceil_sqrt(statExp[source[i]]) / 4;
		unsigned value = ((base[i] + dv) * 2 + term) * level / 100;
		out[i] = (uint16_t) (i == 0 ? value + level + 10 : value + 5);
	}
}

int pk_gb_gender(unsigned dex, const uint8_t dvs[5]) {
	uint8_t ratio;
	if (!pk_gb_base_stats(2, dex, NULL, NULL, NULL, &ratio, NULL)) {
		return 2;
	}
	if (ratio == 255) {
		return 2;
	}
	if (ratio == 0) {
		return 0;
	}
	if (ratio == 254) {
		return 1;
	}
	unsigned value = ((unsigned) dvs[1] << 4) | dvs[3];
	return value <= ratio ? 1 : 0;
}

void pk_gb_hidden_power(const uint8_t dvs[5], uint8_t* type, uint8_t* power) {
	unsigned atk = dvs[1], def = dvs[2], spe = dvs[3], spc = dvs[4];
	if (type) {
		*type = (uint8_t) (((atk & 3) << 2) | (def & 3));
	}
	if (power) {
		unsigned high = (spc >> 3) + 2 * (spe >> 3) + 4 * (def >> 3) + 8 * (atk >> 3);
		*power = (uint8_t) ((5 * high + (spc & 3)) / 2 + 31);
	}
}

/* ---------- Pokemon structures ---------- */

bool pk_gb_mon_decode(int generation, const uint8_t* mon, size_t monSize, const uint8_t* otName,
                      const uint8_t* nickname, uint8_t listSpecies, PKGBMon* out) {
	if (!out) {
		return false;
	}
	memset(out, 0, sizeof(*out));
	size_t boxSize = generation == 1 ? PK_GB1_BOX_MON : PK_GB2_BOX_MON;
	size_t partySize = generation == 1 ? PK_GB1_PARTY_MON : PK_GB2_PARTY_MON;
	if (!mon || (generation != 1 && generation != 2) || monSize < boxSize) {
		return false;
	}
	out->generation = (uint8_t) generation;
	out->species = mon[0];
	out->dex = (uint16_t) dex_of(generation, mon[0]);
	out->isEgg = generation == 2 && listSpecies == 0xFD;
	if (otName) {
		pk_gb_text_decode(otName, PK_GB_NAME_LENGTH, out->otName, sizeof(out->otName));
	}
	if (nickname) {
		pk_gb_text_decode(nickname, PK_GB_NAME_LENGTH, out->nickname, sizeof(out->nickname));
	}

	uint8_t dvAtkDef, dvSpeSpc;
	if (generation == 1) {
		out->hp = be16(mon + 1);
		out->level = mon[3];
		out->status = mon[4];
		out->heldItem = mon[7];
		memcpy(out->moves, mon + 8, 4);
		out->otId = be16(mon + 12);
		out->experience = be24(mon + 14);
		for (int i = 0; i < 5; ++i) {
			out->statExp[i] = be16(mon + 17 + i * 2);
		}
		dvAtkDef = mon[27];
		dvSpeSpc = mon[28];
		for (int i = 0; i < 4; ++i) {
			out->pp[i] = mon[29 + i] & 0x3F;
			out->ppUps[i] = mon[29 + i] >> 6;
		}
		if (monSize >= partySize) {
			out->hasPartyData = true;
			out->level = mon[33];
			out->stats[0] = be16(mon + 34);
			out->stats[1] = be16(mon + 36);
			out->stats[2] = be16(mon + 38);
			out->stats[3] = be16(mon + 40);
			out->stats[4] = be16(mon + 42);
			out->stats[5] = out->stats[4];
		}
	} else {
		out->heldItem = mon[1];
		memcpy(out->moves, mon + 2, 4);
		out->otId = be16(mon + 6);
		out->experience = be24(mon + 8);
		for (int i = 0; i < 5; ++i) {
			out->statExp[i] = be16(mon + 11 + i * 2);
		}
		dvAtkDef = mon[21];
		dvSpeSpc = mon[22];
		for (int i = 0; i < 4; ++i) {
			out->pp[i] = mon[23 + i] & 0x3F;
			out->ppUps[i] = mon[23 + i] >> 6;
		}
		out->friendship = mon[27];
		out->pokerus = mon[28];
		uint16_t caught = be16(mon + 29);
		if (caught != 0) {
			out->hasCaughtData = true;
			out->metTime = (uint8_t) (caught >> 14);
			out->metLevel = (uint8_t) ((caught >> 8) & 0x3F);
			out->otGender = (uint8_t) ((caught >> 7) & 1);
			out->metLocation = (uint8_t) (caught & 0x7F);
		}
		out->level = mon[31];
		if (monSize >= partySize) {
			out->hasPartyData = true;
			out->status = mon[32];
			out->hp = be16(mon + 34);
			for (int i = 0; i < 6; ++i) {
				out->stats[i] = be16(mon + 36 + i * 2);
			}
		}
	}
	out->dvs[1] = dvAtkDef >> 4;
	out->dvs[2] = dvAtkDef & 0x0F;
	out->dvs[3] = dvSpeSpc >> 4;
	out->dvs[4] = dvSpeSpc & 0x0F;
	out->dvs[0] = (uint8_t) (((out->dvs[1] & 1) << 3) | ((out->dvs[2] & 1) << 2) | ((out->dvs[3] & 1) << 1) |
	                         (out->dvs[4] & 1));
	if (generation == 2) {
		out->isShiny = out->dvs[2] == 10 && out->dvs[3] == 10 && out->dvs[4] == 10 && (out->dvs[1] & 2);
	}
	out->valid = out->dex != 0 && out->level >= 1 && out->level <= 100;
	return out->valid;
}

bool pk_gb_blob_decode(int generation, const uint8_t* blob, size_t size, PKGBMon* out) {
	size_t box = generation == 1 ? PK_GB1_BOX_MON : PK_GB2_BOX_MON;
	if (!blob || size < box + 2 * PK_GB_NAME_LENGTH + 1) {
		if (out) {
			memset(out, 0, sizeof(*out));
		}
		return false;
	}
	return pk_gb_mon_decode(generation, blob, box, blob + box, blob + box + PK_GB_NAME_LENGTH,
	                        blob[box + 2 * PK_GB_NAME_LENGTH], out);
}

/* ---------- Team in memory ---------- */

long pk_gb_scan_party(const uint8_t* ram, size_t size, int generation, int* countOut) {
	if (countOut) {
		*countOut = 0;
	}
	if (!ram || (generation != 1 && generation != 2)) {
		return -1;
	}
	size_t monSize = generation == 1 ? PK_GB1_PARTY_MON : PK_GB2_PARTY_MON;
	size_t total = 8 + 6 * monSize + 12 * PK_GB_NAME_LENGTH;
	for (size_t off = 0; off + total <= size; ++off) {
		unsigned count = ram[off];
		if (count < 1 || count > 6 || ram[off + 1 + count] != 0xFF) {
			continue;
		}
		bool ok = true;
		for (unsigned i = 0; i < count && ok; ++i) {
			uint8_t listed = ram[off + 1 + i];
			const uint8_t* mon = ram + off + 8 + i * monSize;
			if (listed != mon[0] && !(generation == 2 && listed == 0xFD)) {
				ok = false;
				break;
			}
			PKGBMon decoded;
			ok = pk_gb_mon_decode(generation, mon, monSize, NULL, NULL, listed, &decoded) && decoded.stats[0] > 0 &&
			     decoded.stats[0] < 1000 && decoded.hp <= decoded.stats[0];
		}
		if (ok) {
			if (countOut) {
				*countOut = (int) count;
			}
			return (long) off;
		}
	}
	return -1;
}

/* ---------- Save files ---------- */

#define GB_SAVE_SIZE 0x8000

typedef struct {
	int game;
	size_t checksumStart, checksumEnd, checksumAt; /* end inclusive */
	size_t trainerId, trainerName;
	size_t currentBox, boxNames, activeBox, party;
	size_t boxStride, boxSize;
	unsigned boxCount, boxesPerBank;
	size_t monSize;
} Layout;

static const Layout kLayouts[] = {
	{ PK_GB_GEN1, 0x2598, 0x3522, 0x3523, 0x2605, 0x2598, 0x284C, 0, 0x30C0, 0x2F2C, 0x462, 0x462, 12, 6, PK_GB1_BOX_MON },
	{ PK_GB_GS, 0x2009, 0x2D68, 0x2D69, 0x2009, 0x200B, 0x2724, 0x2727, 0x2D6C, 0x288A, 0x450, 0x44E, 14, 7, PK_GB2_BOX_MON },
	{ PK_GB_CRYSTAL, 0x2009, 0x2B82, 0x2D0D, 0x2009, 0x200B, 0x2700, 0x2703, 0x2D10, 0x2865, 0x450, 0x44E, 14, 7, PK_GB2_BOX_MON },
};

struct PKGBSave {
	uint8_t* data;
	size_t size;
	const Layout* layout;
	bool bankDirty[2];
};

static bool checksum_ok(const uint8_t* data, const Layout* l) {
	if (l->game == PK_GB_GEN1) {
		uint8_t sum = 0;
		for (size_t i = l->checksumStart; i <= l->checksumEnd; ++i) {
			sum = (uint8_t) (sum + data[i]);
		}
		return (uint8_t) ~sum == data[l->checksumAt];
	}
	uint16_t sum = 0;
	for (size_t i = l->checksumStart; i <= l->checksumEnd; ++i) {
		sum = (uint16_t) (sum + data[i]);
	}
	return sum == (uint16_t) (data[l->checksumAt] | (data[l->checksumAt + 1] << 8));
}

/* A list: count, species terminated by 0xFF. */
static bool list_ok(const uint8_t* list, unsigned capacity) {
	unsigned count = list[0];
	if (count > capacity) {
		return false;
	}
	if (list[1 + count] != 0xFF) {
		return false;
	}
	return true;
}

static int generation_of(const Layout* l) {
	return l->game == PK_GB_GEN1 ? 1 : 2;
}

PKGBSave* pk_gb_save_open(const uint8_t* data, size_t size, int* err) {
	int dummy;
	if (!err) {
		err = &dummy;
	}
	*err = PK_OK;
	if (!data || size < GB_SAVE_SIZE) {
		*err = PK_ERR_SIZE;
		return NULL;
	}
	const Layout* found = NULL;
	for (size_t i = 0; i < sizeof(kLayouts) / sizeof(kLayouts[0]); ++i) {
		const Layout* l = &kLayouts[i];
		if (checksum_ok(data, l) && list_ok(data + l->party, 6) && list_ok(data + l->activeBox, PK_GB_BOX_SLOTS)) {
			found = l;
			break;
		}
	}
	if (!found) {
		*err = PK_ERR_NO_SLOT;
		return NULL;
	}
	PKGBSave* save = calloc(1, sizeof(*save));
	if (!save || !(save->data = malloc(size))) {
		free(save);
		*err = PK_ERR_MEMORY;
		return NULL;
	}
	memcpy(save->data, data, size);
	save->size = size;
	save->layout = found;
	return save;
}

void pk_gb_save_free(PKGBSave* save) {
	if (save) {
		free(save->data);
		free(save);
	}
}

int pk_gb_save_game(const PKGBSave* save) {
	return save ? save->layout->game : 0;
}

int pk_gb_save_generation(const PKGBSave* save) {
	return save ? generation_of(save->layout) : 0;
}

void pk_gb_save_trainer_name(const PKGBSave* save, char* out, size_t outSize) {
	if (!save) {
		if (out && outSize) {
			out[0] = '\0';
		}
		return;
	}
	pk_gb_text_decode(save->data + save->layout->trainerName, PK_GB_NAME_LENGTH, out, outSize);
}

uint16_t pk_gb_save_trainer_id(const PKGBSave* save) {
	return save ? be16(save->data + save->layout->trainerId) : 0;
}

unsigned pk_gb_box_count(const PKGBSave* save) {
	return save ? save->layout->boxCount : 0;
}

int pk_gb_current_box(const PKGBSave* save) {
	if (!save) {
		return 0;
	}
	int box = save->data[save->layout->currentBox] & (save->layout->game == PK_GB_GEN1 ? 0x7F : 0x0F);
	return box < (int) save->layout->boxCount ? box : 0;
}

/* Where a box lives: the active copy for the current box, its bank slot otherwise. */
static uint8_t* box_ptr(const PKGBSave* save, int box) {
	const Layout* l = save->layout;
	if (box == pk_gb_current_box(save)) {
		return save->data + l->activeBox;
	}
	unsigned bank = (unsigned) box / l->boxesPerBank;
	unsigned slot = (unsigned) box % l->boxesPerBank;
	return save->data + (bank == 0 ? 0x4000 : 0x6000) + slot * l->boxStride;
}

bool pk_gb_box_usable(const PKGBSave* save, int box) {
	if (!save || box < 0 || box >= (int) save->layout->boxCount) {
		return false;
	}
	if (box == pk_gb_current_box(save)) {
		return true;
	}
	/* Red/Blue/Yellow set up the stored boxes the first time the player changes box. */
	if (save->layout->game == PK_GB_GEN1 && !(save->data[save->layout->currentBox] & 0x80)) {
		return false;
	}
	return list_ok(box_ptr(save, box), PK_GB_BOX_SLOTS);
}

unsigned pk_gb_box_size(const PKGBSave* save, int box) {
	return pk_gb_box_usable(save, box) ? box_ptr(save, box)[0] : 0;
}

void pk_gb_box_name(const PKGBSave* save, int box, char* out, size_t outSize) {
	if (!out || outSize == 0) {
		return;
	}
	out[0] = '\0';
	if (!save || box < 0 || box >= (int) save->layout->boxCount) {
		return;
	}
	if (save->layout->boxNames) {
		pk_gb_text_decode(save->data + save->layout->boxNames + (size_t) box * 9, 9, out, outSize);
	}
}

size_t pk_gb_blob_size(const PKGBSave* save) {
	if (!save) {
		return 0;
	}
	return generation_of(save->layout) == 1 ? PK_GB1_BLOB : PK_GB2_BLOB;
}

static size_t ots_offset(const Layout* l) {
	return 22 + PK_GB_BOX_SLOTS * l->monSize;
}

static size_t nicks_offset(const Layout* l) {
	return ots_offset(l) + PK_GB_BOX_SLOTS * PK_GB_NAME_LENGTH;
}

bool pk_gb_box_mon(const PKGBSave* save, int box, int index, uint8_t* blob) {
	if (!save || !blob || index < 0 || index >= (int) pk_gb_box_size(save, box)) {
		return false;
	}
	const Layout* l = save->layout;
	const uint8_t* b = box_ptr(save, box);
	memcpy(blob, b + 22 + (size_t) index * l->monSize, l->monSize);
	memcpy(blob + l->monSize, b + ots_offset(l) + (size_t) index * PK_GB_NAME_LENGTH, PK_GB_NAME_LENGTH);
	memcpy(blob + l->monSize + PK_GB_NAME_LENGTH, b + nicks_offset(l) + (size_t) index * PK_GB_NAME_LENGTH,
	       PK_GB_NAME_LENGTH);
	blob[l->monSize + 2 * PK_GB_NAME_LENGTH] = b[1 + index];
	return true;
}

static void mark_dirty(PKGBSave* save, int box) {
	if (box != pk_gb_current_box(save)) {
		save->bankDirty[(unsigned) box / save->layout->boxesPerBank] = true;
	}
}

int pk_gb_box_remove(PKGBSave* save, int box, int index) {
	if (!save || index < 0 || index >= (int) pk_gb_box_size(save, box)) {
		return PK_ERR_RANGE;
	}
	const Layout* l = save->layout;
	uint8_t* b = box_ptr(save, box);
	unsigned count = b[0];
	unsigned after = count - 1 - (unsigned) index;
	/* Close the gap in each of the four parallel lists. */
	memmove(b + 1 + index, b + 2 + index, after + 1); /* species, with the terminator */
	b[count] = 0xFF;
	b[1 + count] = 0x00;
	uint8_t* mons = b + 22;
	memmove(mons + (size_t) index * l->monSize, mons + (size_t) (index + 1) * l->monSize, after * l->monSize);
	memset(mons + (size_t) (count - 1) * l->monSize, 0, l->monSize);
	uint8_t* ots = b + ots_offset(l);
	memmove(ots + (size_t) index * PK_GB_NAME_LENGTH, ots + (size_t) (index + 1) * PK_GB_NAME_LENGTH,
	        after * PK_GB_NAME_LENGTH);
	memset(ots + (size_t) (count - 1) * PK_GB_NAME_LENGTH, 0, PK_GB_NAME_LENGTH);
	uint8_t* nicks = b + nicks_offset(l);
	memmove(nicks + (size_t) index * PK_GB_NAME_LENGTH, nicks + (size_t) (index + 1) * PK_GB_NAME_LENGTH,
	        after * PK_GB_NAME_LENGTH);
	memset(nicks + (size_t) (count - 1) * PK_GB_NAME_LENGTH, 0, PK_GB_NAME_LENGTH);
	b[0] = (uint8_t) (count - 1);
	mark_dirty(save, box);
	return PK_OK;
}

int pk_gb_box_append(PKGBSave* save, int box, const uint8_t* blob, size_t size) {
	if (!save || !pk_gb_box_usable(save, box)) {
		return PK_ERR_RANGE;
	}
	const Layout* l = save->layout;
	PKGBMon check;
	if (size != pk_gb_blob_size(save) || !pk_gb_blob_decode(generation_of(l), blob, size, &check)) {
		return PK_ERR_INVALID_MON;
	}
	uint8_t* b = box_ptr(save, box);
	unsigned count = b[0];
	if (count >= PK_GB_BOX_SLOTS) {
		return PK_ERR_OCCUPIED;
	}
	memcpy(b + 22 + (size_t) count * l->monSize, blob, l->monSize);
	memcpy(b + ots_offset(l) + (size_t) count * PK_GB_NAME_LENGTH, blob + l->monSize, PK_GB_NAME_LENGTH);
	memcpy(b + nicks_offset(l) + (size_t) count * PK_GB_NAME_LENGTH, blob + l->monSize + PK_GB_NAME_LENGTH,
	       PK_GB_NAME_LENGTH);
	b[1 + count] = blob[l->monSize + 2 * PK_GB_NAME_LENGTH];
	b[2 + count] = 0xFF;
	b[0] = (uint8_t) (count + 1);
	mark_dirty(save, box);
	return PK_OK;
}

bool pk_gb_first_free(const PKGBSave* save, int* box) {
	if (!save) {
		return false;
	}
	int current = pk_gb_current_box(save);
	if (pk_gb_box_size(save, current) < PK_GB_BOX_SLOTS) {
		if (box) {
			*box = current;
		}
		return true;
	}
	for (int b = 0; b < (int) save->layout->boxCount; ++b) {
		if (pk_gb_box_usable(save, b) && pk_gb_box_size(save, b) < PK_GB_BOX_SLOTS) {
			if (box) {
				*box = b;
			}
			return true;
		}
	}
	return false;
}

size_t pk_gb_save_size(const PKGBSave* save) {
	return save ? save->size : 0;
}

static uint8_t gen1_sum(const uint8_t* data, size_t start, size_t length) {
	uint8_t sum = 0;
	for (size_t i = 0; i < length; ++i) {
		sum = (uint8_t) (sum + data[start + i]);
	}
	return (uint8_t) ~sum;
}

size_t pk_gb_save_write(const PKGBSave* save, uint8_t* out, size_t outSize) {
	if (!save || !out || outSize < save->size) {
		return 0;
	}
	memcpy(out, save->data, save->size);
	const Layout* l = save->layout;
	if (l->game == PK_GB_GEN1) {
		/* The active box is inside the main data. */
		out[l->checksumAt] = gen1_sum(out, l->checksumStart, l->checksumEnd - l->checksumStart + 1);
		for (int bank = 0; bank < 2; ++bank) {
			if (!save->bankDirty[bank]) {
				continue;
			}
			size_t base = bank == 0 ? 0x4000 : 0x6000;
			for (unsigned i = 0; i < l->boxesPerBank; ++i) {
				out[base + 0x1A4D + i] = gen1_sum(out, base + i * l->boxStride, l->boxSize);
			}
			out[base + 0x1A4C] = gen1_sum(out, base, 0x1A4C);
		}
	}
	/* Gold, Silver and Crystal do not checksum the boxes, and the main data
	 * (which is) is never changed here. */
	return save->size;
}
