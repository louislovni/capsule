/* Pokemon of the DS games (generations 4 and 5): the 136-byte structure and
 * the PC boxes of the save files.
 *
 * Layouts follow PKHeX (https://github.com/kwsch/PKHeX, GPL v3):
 *   generation 4: two 256 KB partitions, each with a "general" and a "storage"
 *   block; the newest of each (save counters in the footer) is the one in use.
 *   Every block ends with a CRC-16-CCITT of its content.
 *   generation 5: one main area of fixed blocks, each with its CRC stored after
 *   it and again in a table near the end, which has a CRC of its own.
 *
 * Licensed under the GNU GPL v3 (see LICENSE).
 */
#include <stdlib.h>
#include <string.h>

#include "pkcore.h"

#define PARTITION 0x40000

static uint16_t rd16(const uint8_t* p) { return (uint16_t) (p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t* p) { return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24); }
static void wr16(uint8_t* p, uint16_t v) {
	p[0] = (uint8_t) v;
	p[1] = (uint8_t) (v >> 8);
}
static void wr32(uint8_t* p, uint32_t v) {
	wr16(p, (uint16_t) v);
	wr16(p + 2, (uint16_t) (v >> 16));
}

static uint16_t crc16_ccitt(const uint8_t* data, size_t size) {
	uint8_t top = 0xFF, bot = 0xFF;
	for (size_t i = 0; i < size; ++i) {
		unsigned x = data[i] ^ top;
		x ^= x >> 4;
		top = (uint8_t) (bot ^ (x >> 3) ^ (x << 4));
		bot = (uint8_t) (x ^ (x << 5));
	}
	return (uint16_t) ((top << 8) | bot);
}

/* ---------- Text ---------- */

static size_t put_utf8(char* out, size_t outSize, size_t at, uint32_t cp) {
	char buf[4];
	size_t n;
	if (cp < 0x80) {
		buf[0] = (char) cp;
		n = 1;
	} else if (cp < 0x800) {
		buf[0] = (char) (0xC0 | (cp >> 6));
		buf[1] = (char) (0x80 | (cp & 0x3F));
		n = 2;
	} else {
		buf[0] = (char) (0xE0 | (cp >> 12));
		buf[1] = (char) (0x80 | ((cp >> 6) & 0x3F));
		buf[2] = (char) (0x80 | (cp & 0x3F));
		n = 3;
	}
	if (at + n >= outSize) return at;
	memcpy(out + at, buf, n);
	return at + n;
}

static void decode_text(int generation, const uint8_t* in, size_t chars, char* out, size_t outSize) {
	size_t at = 0;
	if (outSize == 0) return;
	for (size_t i = 0; i < chars; ++i) {
		uint16_t value = rd16(in + 2 * i);
		if (value == 0xFFFF || value == 0) break;
		uint32_t cp;
		if (generation == 4) {
			cp = value < pk_nds_charset_count ? pk_nds_charset[value] : 0;
			if (cp == 0) cp = '?';
		} else {
			cp = value;
			if (cp >= 0xD800 && cp < 0xE000) cp = '?';
		}
		if (cp == 0x246D) cp = 0x2642; /* the games' own male and female signs */
		if (cp == 0x246E) cp = 0x2640;
		if (cp == 0x3000) cp = ' ';
		at = put_utf8(out, outSize, at, cp);
	}
	out[at] = 0;
}

/* ---------- Structure ---------- */

static const char kOrders[24][5] = {
	"ABCD", "ABDC", "ACBD", "ACDB", "ADBC", "ADCB", "BACD", "BADC", "BCAD", "BCDA", "BDAC", "BDCA",
	"CABD", "CADB", "CBAD", "CBDA", "CDAB", "CDBA", "DABC", "DACB", "DBAC", "DBCA", "DCAB", "DCBA",
};

void pk_nds_crypt(uint8_t* raw) {
	uint32_t seed = rd16(raw + 6);
	for (int i = 0; i < 64; ++i) {
		seed = seed * 0x41C64E6Du + 0x6073u;
		uint8_t* p = raw + 8 + 2 * i;
		wr16(p, (uint16_t) (rd16(p) ^ (seed >> 16)));
	}
}

/* Decrypts and puts blocks in A, B, C, D order. */
static void unpack(const uint8_t* raw, uint8_t* out) {
	uint8_t tmp[PK_NDS_MON_SIZE];
	memcpy(tmp, raw, PK_NDS_MON_SIZE);
	pk_nds_crypt(tmp);
	unsigned order = ((rd32(tmp) & 0x3E000u) >> 13) % 24;
	memcpy(out, tmp, 8);
	for (int pos = 0; pos < 4; ++pos) {
		int block = kOrders[order][pos] - 'A';
		memcpy(out + 8 + 32 * block, tmp + 8 + 32 * pos, 32);
	}
}

static uint16_t data_checksum(const uint8_t* plain) {
	uint16_t sum = 0;
	for (int i = 8; i < PK_NDS_MON_SIZE; i += 2) sum = (uint16_t) (sum + rd16(plain + i));
	return sum;
}

bool pk_nds_mon_is_empty(const uint8_t* raw) {
	bool zero = true;
	for (int i = 0; i < PK_NDS_MON_SIZE && zero; ++i) zero = raw[i] == 0;
	if (zero) return true;
	uint8_t plain[PK_NDS_MON_SIZE];
	unpack(raw, plain);
	return rd16(plain + 0x08) == 0;
}

void pk_nds_empty_slot(uint8_t* raw) {
	memset(raw, 0, PK_NDS_MON_SIZE);
	pk_nds_crypt(raw);
}

static unsigned popcount32(uint32_t v) {
	unsigned n = 0;
	for (; v; v &= v - 1) ++n;
	return n;
}

bool pk_nds_mon_decode(int generation, const uint8_t* raw, size_t size, PKNDSMon* out) {
	memset(out, 0, sizeof(*out));
	if (!raw || size < PK_NDS_MON_SIZE || (generation != 4 && generation != 5)) return false;
	uint8_t u[PK_NDS_MON_SIZE];
	unpack(raw, u);
	out->generation = (uint8_t) generation;
	out->personality = rd32(u);
	out->species = rd16(u + 0x08);
	if (out->species == 0 || data_checksum(u) != rd16(u + 6)) return false;
	if (out->species > (generation == 4 ? 493 : 649)) return false;

	out->heldItem = rd16(u + 0x0A);
	out->tid = rd16(u + 0x0C);
	out->sid = rd16(u + 0x0E);
	out->experience = rd32(u + 0x10);
	out->friendship = u[0x14];
	out->ability = u[0x15];
	out->markings = u[0x16];
	out->language = u[0x17];
	memcpy(out->evs, u + 0x18, 6);
	memcpy(out->contest, u + 0x1E, 6);
	for (int i = 0; i < 4; ++i) {
		out->moves[i] = rd16(u + 0x28 + 2 * i);
		out->pp[i] = u[0x30 + i];
		out->ppUps[i] = u[0x34 + i];
	}
	uint32_t iv = rd32(u + 0x38);
	for (int i = 0; i < 6; ++i) out->ivs[i] = (uint8_t) ((iv >> (5 * i)) & 31);
	out->isEgg = (iv >> 30) & 1;
	out->isNicknamed = (iv >> 31) & 1;
	uint8_t flags = u[0x40];
	out->fatefulEncounter = flags & 1;
	out->gender = (flags & 4) ? 2 : (flags & 2) ? 1 : 0;
	out->form = flags >> 3;
	if (generation == 5) {
		out->nature = u[0x41] < 25 ? u[0x41] : (uint8_t) (out->personality % 25);
		out->hiddenAbility = u[0x42] & 1;
	} else {
		out->nature = (uint8_t) (out->personality % 25);
	}
	out->originGame = u[0x5F];
	out->eggYear = u[0x78];
	out->eggMonth = u[0x79];
	out->eggDay = u[0x7A];
	out->metYear = u[0x7B];
	out->metMonth = u[0x7C];
	out->metDay = u[0x7D];
	out->eggLocation = rd16(u + 0x7E);
	out->metLocation = rd16(u + 0x80);
	if (generation == 4) {
		/* Platinum and HeartGold/SoulSilver keep their newer locations apart. */
		if (rd16(u + 0x44)) out->eggLocation = rd16(u + 0x44);
		if (rd16(u + 0x46)) out->metLocation = rd16(u + 0x46);
	}
	out->pokerus = u[0x82];
	out->ball = u[0x83];
	if (generation == 4 && u[0x86] > out->ball) out->ball = u[0x86];
	out->metLevel = u[0x84] & 0x7F;
	out->otGender = u[0x84] >> 7;
	out->encounterType = u[0x85];
	out->ribbonCount = popcount32(rd32(u + 0x24)) + popcount32(rd32(u + 0x3C)) + popcount32(rd32(u + 0x60));

	unsigned pidx = (out->personality >> 16) ^ (out->personality & 0xFFFF);
	out->isShiny = (out->tid ^ out->sid ^ pidx) < 8;

	unsigned type = 0, power = 0;
	for (int i = 0; i < 6; ++i) {
		type |= (out->ivs[i] & 1u) << i;
		power |= ((out->ivs[i] >> 1) & 1u) << i;
	}
	out->hiddenPowerType = (uint8_t) (type * 15 / 63);
	out->hiddenPowerPower = (uint8_t) (power * 40 / 63 + 30);

	decode_text(generation, u + 0x48, 11, out->nickname, sizeof(out->nickname));
	decode_text(generation, u + 0x68, 8, out->otName, sizeof(out->otName));
	out->valid = true;
	return true;
}

/* ---------- Names and stats ---------- */

const char* pk_nds_species_name(unsigned dex) { return dex < 650 ? pk_nds_species_names[dex] : NULL; }
const char* pk_nds_move_name(unsigned move) { return move < 560 ? pk_nds_move_names[move] : NULL; }
const char* pk_nds_ability_name(unsigned ability) { return ability < 165 ? pk_nds_ability_names[ability] : NULL; }
const char* pk_nds_item_name(unsigned item) { return item < 639 ? pk_nds_item_names[item] : NULL; }

const char* pk_nds_type_name(unsigned type) { return type < 17 ? pk_nds_type_names[type] : NULL; }

bool pk_nds_base_stats(unsigned dex, PKNDSBase* out) {
	if (dex == 0 || dex >= 650) return false;
	*out = pk_nds_base[dex];
	return true;
}

const char* pk_nds_ball_name(unsigned ball) {
	if (ball >= 1 && ball <= 16) return pk_nds_item_name(ball);
	if (ball >= 17 && ball <= 24) return pk_nds_item_name(492 + ball - 17);
	if (ball == 25) return pk_nds_item_name(576);
	return NULL;
}

uint8_t pk_nds_level(unsigned dex, uint32_t exp) {
	if (dex == 0 || dex >= 650) return 0;
	return pk_level_for_exp(pk_nds_base[dex].growthRate, exp);
}

bool pk_nds_calc_stats(unsigned dex, const uint8_t ivs[6], const uint8_t evs[6], unsigned level, unsigned nature,
                       uint16_t out[6]) {
	if (dex == 0 || dex >= 650 || level == 0) return false;
	PKBaseStats base;
	memset(&base, 0, sizeof(base));
	memcpy(base.baseStats, pk_nds_base[dex].stats, 6);
	pk_calc_stats(&base, ivs, evs, level, nature, 0, out);
	if (dex == 292) out[0] = 1; /* Shedinja */
	return true;
}

/* ---------- Save files ---------- */

struct PKNDSSave {
	uint8_t* data;
	size_t size;
	int game;
	int generation;
	/* Generation 4: the blocks in use (absolute offsets). */
	size_t general, generalSize;
	size_t storage, storageSize, footerSize;
	size_t boxBase, boxStride, boxNames;
	size_t currentBoxOffset;
	/* Generation 5. */
	size_t mainSize, infoLength;
	unsigned boxCount;
	uint32_t dirtyBoxes;
};

typedef struct {
	int game;
	size_t generalSize, storageStart, storageSize, footerSize, trainer;
} Gen4Layout;

static const Gen4Layout kGen4[] = {
	{PK_NDS_DP, 0xC100, 0xC100, 0x121E0, 0x14, 0x64},
	{PK_NDS_PT, 0xCF2C, 0xCF2C, 0x121E4, 0x14, 0x68},
	{PK_NDS_HGSS, 0xF628, 0xF700, 0x12310, 0x10, 0x64},
};

enum { FIRST = 0, SECOND = 1, SAME = 2 };

static int compare_counters(uint32_t a, uint32_t b) {
	if (a == 0xFFFFFFFFu && b != 0xFFFFFFFEu) return SECOND;
	if (b == 0xFFFFFFFFu && a != 0xFFFFFFFEu) return FIRST;
	if (a > b) return FIRST;
	if (a < b) return SECOND;
	return SAME;
}

/* Which partition holds the newest copy of a block (PKHeX's rule). */
static int newest(const uint8_t* data, size_t begin, size_t length) {
	size_t a = begin + length - 0x14, b = a + PARTITION;
	int major = compare_counters(rd32(data + a), rd32(data + b));
	if (major != SAME) return major;
	return compare_counters(rd32(data + a + 4), rd32(data + b + 4)) == SECOND ? SECOND : FIRST;
}

static bool block_ok(const uint8_t* block, size_t size, size_t footer) {
	if (rd32(block + size - 0xC) != size) return false;
	return crc16_ccitt(block, size - footer) == rd16(block + size - 2);
}

/* Picks the copy in use, falling back to the other if its checksum is bad. */
static bool pick_block(const uint8_t* data, size_t begin, size_t length, size_t footer, size_t* where) {
	int first = newest(data, begin, length);
	size_t preferred = begin + (first == FIRST ? 0 : PARTITION);
	size_t other = begin + (first == FIRST ? PARTITION : 0);
	if (block_ok(data + preferred, length, footer)) {
		*where = preferred;
		return true;
	}
	if (block_ok(data + other, length, footer)) {
		*where = other;
		return true;
	}
	return false;
}

static bool open_gen4(PKNDSSave* s, int* err) {
	for (size_t i = 0; i < sizeof(kGen4) / sizeof(kGen4[0]); ++i) {
		const Gen4Layout* l = &kGen4[i];
		bool sized = false;
		for (size_t p = 0; p < 2 * PARTITION; p += PARTITION)
			if (rd32(s->data + p + l->generalSize - 0xC) == l->generalSize &&
			    rd32(s->data + p + l->storageStart + l->storageSize - 0xC) == l->storageSize)
				sized = true;
		if (!sized) continue;
		if (!pick_block(s->data, 0, l->generalSize, l->footerSize, &s->general) ||
		    !pick_block(s->data, l->storageStart, l->storageSize, l->footerSize, &s->storage)) {
			*err = PK_ERR_CHECKSUM;
			return false;
		}
		s->game = l->game;
		s->generation = 4;
		s->generalSize = l->generalSize;
		s->storageSize = l->storageSize;
		s->footerSize = l->footerSize;
		s->boxCount = 18;
		if (l->game == PK_NDS_HGSS) {
			s->boxBase = 0;
			s->boxStride = 0x1000;
			s->boxNames = 0x12008;
			s->currentBoxOffset = 0x12000;
		} else {
			s->boxBase = 4;
			s->boxStride = 0xFF0;
			s->boxNames = 4 + 18 * 0xFF0;
			s->currentBoxOffset = 0;
		}
		s->general += l->trainer; /* only the trainer is read from there */
		return true;
	}
	return false;
}

static size_t gen5_footer(const PKNDSSave* s) { return s->mainSize - 0x100; }

static bool gen5_block_ok(const uint8_t* data, size_t offset, size_t length, size_t mirror) {
	uint16_t crc = crc16_ccitt(data + offset, length);
	return crc == rd16(data + offset + length + 2) && crc == rd16(data + mirror);
}

static bool open_gen5(PKNDSSave* s, int* err) {
	static const struct { int game; size_t mainSize, infoLength; } kinds[] = {
		{PK_NDS_BW, 0x24000, 0x8C},
		{PK_NDS_B2W2, 0x26000, 0x94},
	};
	for (size_t k = 0; k < 2; ++k) {
		size_t footer = kinds[k].mainSize - 0x100;
		const uint8_t* info = s->data + footer;
		if (crc16_ccitt(info, kinds[k].infoLength) != rd16(info + kinds[k].infoLength + 0xE)) continue;
		s->game = kinds[k].game;
		s->generation = 5;
		s->mainSize = kinds[k].mainSize;
		s->infoLength = kinds[k].infoLength;
		/* Box names and layout, then the 24 boxes. */
		if (!gen5_block_ok(s->data, 0, 0x3E0, footer)) {
			*err = PK_ERR_CHECKSUM;
			return false;
		}
		for (int box = 0; box < 24; ++box) {
			if (!gen5_block_ok(s->data, 0x400 + 0x1000 * (size_t) box, 0xFF0, footer + 2 + 2 * (size_t) box)) {
				*err = PK_ERR_CHECKSUM;
				return false;
			}
		}
		unsigned unlocked = s->data[0x3DD];
		s->boxCount = unlocked == 0 ? 8 : unlocked > 24 ? 24 : unlocked;
		s->boxBase = 0x400;
		s->boxStride = 0x1000;
		s->boxNames = 4;
		s->currentBoxOffset = 0;
		s->storage = 0;
		s->general = 0x19400 + 4;
		return true;
	}
	return false;
}

PKNDSSave* pk_nds_save_open(const uint8_t* data, size_t size, int* err) {
	int dummy;
	if (!err) err = &dummy;
	*err = PK_OK;
	if (!data || size < PK_NDS_SAVE_SIZE) {
		*err = PK_ERR_SIZE;
		return NULL;
	}
	PKNDSSave* s = calloc(1, sizeof(*s));
	if (!s || !(s->data = malloc(size))) {
		free(s);
		*err = PK_ERR_MEMORY;
		return NULL;
	}
	memcpy(s->data, data, size);
	s->size = size;
	if (open_gen4(s, err) || (*err == PK_OK && open_gen5(s, err))) return s;
	if (*err == PK_OK) *err = PK_ERR_NO_SLOT;
	pk_nds_save_free(s);
	return NULL;
}

void pk_nds_save_free(PKNDSSave* s) {
	if (!s) return;
	free(s->data);
	free(s);
}

int pk_nds_save_game(const PKNDSSave* s) { return s->game; }
int pk_nds_save_generation(const PKNDSSave* s) { return s->generation; }

void pk_nds_save_trainer_name(const PKNDSSave* s, char* out, size_t outSize) {
	decode_text(s->generation, s->data + s->general, 8, out, outSize);
}

uint16_t pk_nds_save_trainer_id(const PKNDSSave* s) { return rd16(s->data + s->general + 0x10); }

unsigned pk_nds_box_count(const PKNDSSave* s) { return s->boxCount; }

int pk_nds_current_box(const PKNDSSave* s) {
	int box = s->data[s->storage + s->currentBoxOffset];
	return box < (int) s->boxCount ? box : 0;
}

void pk_nds_box_name(const PKNDSSave* s, int box, char* out, size_t outSize) {
	if (outSize) out[0] = 0;
	if (box < 0 || box >= (int) s->boxCount) return;
	size_t stride = s->generation == 4 ? 40 : 0x28;
	size_t chars = s->generation == 4 ? 20 : 10;
	decode_text(s->generation, s->data + s->storage + s->boxNames + stride * (size_t) box, chars, out, outSize);
}

static uint8_t* slot_ptr(const PKNDSSave* s, int box, int slot) {
	if (box < 0 || box >= (int) s->boxCount || slot < 0 || slot >= 30) return NULL;
	return s->data + s->storage + s->boxBase + s->boxStride * (size_t) box + PK_NDS_MON_SIZE * (size_t) slot;
}

bool pk_nds_box_mon(const PKNDSSave* s, int box, int slot, uint8_t* raw) {
	const uint8_t* p = slot_ptr(s, box, slot);
	if (!p || pk_nds_mon_is_empty(p)) return false;
	memcpy(raw, p, PK_NDS_MON_SIZE);
	return true;
}

/* What the game can hold: a newer Pokemon, move or item would break it. */
static bool fits_game(const PKNDSSave* s, const PKNDSMon* mon) {
	unsigned maxItem, maxMove, maxAbility;
	switch (s->game) {
	case PK_NDS_DP: maxItem = 464, maxMove = 467, maxAbility = 123; break;
	case PK_NDS_PT: maxItem = 467, maxMove = 467, maxAbility = 123; break;
	case PK_NDS_HGSS: maxItem = 536, maxMove = 467, maxAbility = 123; break;
	case PK_NDS_BW: maxItem = 632, maxMove = 559, maxAbility = 164; break;
	default: maxItem = 638, maxMove = 559, maxAbility = 164; break;
	}
	if (mon->heldItem > maxItem || mon->ability > maxAbility) return false;
	for (int i = 0; i < 4; ++i)
		if (mon->moves[i] > maxMove) return false;
	return true;
}

int pk_nds_put_box_mon(PKNDSSave* s, int box, int slot, const uint8_t* raw) {
	uint8_t* p = slot_ptr(s, box, slot);
	if (!p) return PK_ERR_RANGE;
	PKNDSMon mon;
	if (!pk_nds_mon_decode(s->generation, raw, PK_NDS_MON_SIZE, &mon) || !fits_game(s, &mon)) return PK_ERR_INVALID_MON;
	if (!pk_nds_mon_is_empty(p)) return PK_ERR_OCCUPIED;
	memcpy(p, raw, PK_NDS_MON_SIZE);
	s->dirtyBoxes |= 1u << box;
	return PK_OK;
}

int pk_nds_clear_box_mon(PKNDSSave* s, int box, int slot) {
	uint8_t* p = slot_ptr(s, box, slot);
	if (!p) return PK_ERR_RANGE;
	pk_nds_empty_slot(p);
	s->dirtyBoxes |= 1u << box;
	return PK_OK;
}

bool pk_nds_first_empty(const PKNDSSave* s, int* box, int* slot) {
	int start = pk_nds_current_box(s);
	for (unsigned n = 0; n < s->boxCount; ++n) {
		int b = (int) ((start + n) % s->boxCount);
		for (int i = 0; i < 30; ++i) {
			if (pk_nds_mon_is_empty(slot_ptr(s, b, i))) {
				*box = b;
				*slot = i;
				return true;
			}
		}
	}
	return false;
}

size_t pk_nds_save_size(const PKNDSSave* s) { return s->size; }

size_t pk_nds_save_write(const PKNDSSave* s, uint8_t* out, size_t outSize) {
	if (outSize < s->size) return 0;
	memcpy(out, s->data, s->size);
	if (s->generation == 4) {
		uint8_t* block = out + s->storage;
		if (s->game == PK_NDS_HGSS && s->dirtyBoxes) {
			/* The game only re-saves boxes marked as changed: mark them all so
			 * its next save copies every box to the other partition. */
			wr32(block + 0x12004, 0x3FFFF);
		}
		wr16(block + s->storageSize - 2, crc16_ccitt(block, s->storageSize - s->footerSize));
	} else {
		size_t footer = gen5_footer(s);
		for (int box = 0; box < 24; ++box) {
			if (!(s->dirtyBoxes & (1u << box))) continue;
			size_t offset = 0x400 + 0x1000 * (size_t) box;
			uint16_t crc = crc16_ccitt(out + offset, 0xFF0);
			wr16(out + offset + 0xFF2, crc);
			wr16(out + footer + 2 + 2 * (size_t) box, crc);
		}
		wr16(out + footer + s->infoLength + 0xE, crc16_ccitt(out + footer, s->infoLength));
	}
	return s->size;
}

/* ---------- Changes ---------- */

/* Shuffles plain A, B, C, D blocks back into the stored order and encrypts them. */
static void pack(const uint8_t* plain, uint8_t* raw) {
	unsigned order = ((rd32(plain) & 0x3E000u) >> 13) % 24;
	memcpy(raw, plain, 8);
	for (int pos = 0; pos < 4; ++pos) {
		int block = kOrders[order][pos] - 'A';
		memcpy(raw + 8 + 32 * pos, plain + 8 + 32 * block, 32);
	}
	pk_nds_crypt(raw);
}

static int utf8_next(const char** s) {
	const unsigned char* p = (const unsigned char*) *s;
	if (!*p) return -1;
	int cp, extra;
	if (p[0] < 0x80) { cp = p[0]; extra = 0; }
	else if ((p[0] & 0xE0) == 0xC0) { cp = p[0] & 0x1F; extra = 1; }
	else if ((p[0] & 0xF0) == 0xE0) { cp = p[0] & 0x0F; extra = 2; }
	else { cp = p[0] & 0x07; extra = 3; }
	++p;
	for (int i = 0; i < extra; ++i, ++p) {
		if ((*p & 0xC0) != 0x80) return -2;
		cp = (cp << 6) | (*p & 0x3F);
	}
	*s = (const char*) p;
	return cp;
}

static bool encode_text(int generation, const char* text, uint8_t* out, size_t chars) {
	uint16_t buf[11];
	size_t n = 0;
	const char* s = text;
	int cp;
	while ((cp = utf8_next(&s)) >= 0) {
		if (n + 1 >= chars) return false;
		uint16_t value = 0;
		if (generation == 4) {
			if (cp == 0x2642) cp = 0x246D; /* stored as the games' own signs, see decode_text */
			if (cp == 0x2640) cp = 0x246E;
			for (size_t i = 1; i < pk_nds_charset_count; ++i) {
				if (pk_nds_charset[i] == (uint32_t) cp) {
					value = (uint16_t) i;
					break;
				}
			}
			if (value == 0) return false;
		} else {
			if (cp > 0xFFFF) return false;
			value = (uint16_t) cp;
		}
		buf[n++] = value;
	}
	if (cp == -2 || n == 0) return false;
	for (size_t i = 0; i < chars; ++i) {
		wr16(out + 2 * i, i < n ? buf[i] : 0xFFFF);
	}
	return true;
}

bool pk_nds_set_species(int generation, uint8_t* raw, uint16_t species, uint16_t heldItem, int ability,
                        const char* nickname) {
	PKNDSMon mon;
	if (!raw || species == 0 || species > (generation == 4 ? 493 : 649) ||
	    !pk_nds_mon_decode(generation, raw, PK_NDS_MON_SIZE, &mon)) {
		return false;
	}
	uint8_t u[PK_NDS_MON_SIZE];
	unpack(raw, u);
	wr16(u + 0x08, species);
	wr16(u + 0x0A, heldItem);
	if (ability >= 0 && ability < 256) u[0x15] = (uint8_t) ability;
	if (nickname && !encode_text(generation, nickname, u + 0x48, 11)) return false;
	wr16(u + 6, data_checksum(u));
	pack(u, raw);
	return true;
}
