/* Tests of the DS (generations 4 and 5) structure and save code.
 *
 * Sample Pokemon in tests/data come from PKHeX's test suite (GPL v3); they are
 * stored decrypted, so they are encrypted here the way the games store them.
 * Saves are synthetic: built with the layouts and checksums, then checked
 * against an independent reading of the bytes.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pkcore.h"

static int failures = 0;
#define CHECK(cond)                                                              \
	do {                                                                         \
		if (!(cond)) {                                                           \
			fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
			++failures;                                                          \
		}                                                                        \
	} while (0)

static uint16_t rd16(const uint8_t* p) { return (uint16_t) (p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t* p) { return rd16(p) | ((uint32_t) rd16(p + 2) << 16); }
static void wr16(uint8_t* p, uint16_t v) {
	p[0] = (uint8_t) v;
	p[1] = (uint8_t) (v >> 8);
}
static void wr32(uint8_t* p, uint32_t v) {
	wr16(p, (uint16_t) v);
	wr16(p + 2, (uint16_t) (v >> 16));
}

/* Independent CRC-16-CCITT (bitwise, polynomial 0x1021, initial 0xFFFF). */
static uint16_t crc_ref(const uint8_t* data, size_t size) {
	uint16_t crc = 0xFFFF;
	for (size_t i = 0; i < size; ++i) {
		crc ^= (uint16_t) (data[i] << 8);
		for (int b = 0; b < 8; ++b) crc = (uint16_t) ((crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1);
	}
	return crc;
}

/* Block positions of PKHeX (PokeCrypto.BlockPosition): where block i is stored. */
static const uint8_t kPos[24][4] = {
	{0, 1, 2, 3}, {0, 1, 3, 2}, {0, 2, 1, 3}, {0, 3, 1, 2}, {0, 2, 3, 1}, {0, 3, 2, 1},
	{1, 0, 2, 3}, {1, 0, 3, 2}, {2, 0, 1, 3}, {3, 0, 1, 2}, {2, 0, 3, 1}, {3, 0, 2, 1},
	{1, 2, 0, 3}, {1, 3, 0, 2}, {2, 1, 0, 3}, {3, 1, 0, 2}, {2, 3, 0, 1}, {3, 2, 0, 1},
	{1, 2, 3, 0}, {1, 3, 2, 0}, {2, 1, 3, 0}, {3, 1, 2, 0}, {2, 3, 1, 0}, {3, 2, 1, 0},
};

/* Decrypted (PKHeX file) to stored form. */
static void pack(const uint8_t* plain, uint8_t* out) {
	unsigned sv = ((rd32(plain) >> 13) & 31) % 24;
	memcpy(out, plain, 8);
	for (int b = 0; b < 4; ++b) memcpy(out + 8 + 32 * kPos[sv][b], plain + 8 + 32 * b, 32);
	uint32_t seed = rd16(plain + 6);
	for (int i = 0; i < 64; ++i) {
		seed = seed * 0x41C64E6Du + 0x6073u;
		uint8_t* p = out + 8 + 2 * i;
		wr16(p, (uint16_t) (rd16(p) ^ (seed >> 16)));
	}
}

static bool load(const char* name, uint8_t* plain) {
	char path[512];
	snprintf(path, sizeof(path), "%s/%s", TEST_DATA, name);
	FILE* f = fopen(path, "rb");
	if (!f) return false;
	size_t n = fread(plain, 1, PK_NDS_MON_SIZE, f);
	fclose(f);
	return n == PK_NDS_MON_SIZE;
}

static void test_samples(uint8_t* mon4, uint8_t* mon5) {
	struct { const char* file; int gen; unsigned species; } samples[] = {
		{"egg236.pk4", 4, 236}, {"roserade407.pk4", 4, 407}, {"haxorus612.pk5", 5, 612}, {"cottonee546.pk5", 5, 546},
	};
	for (size_t i = 0; i < 4; ++i) {
		uint8_t plain[PK_NDS_MON_SIZE], stored[PK_NDS_MON_SIZE];
		CHECK(load(samples[i].file, plain));
		pack(plain, stored);
		PKNDSMon mon;
		CHECK(pk_nds_mon_decode(samples[i].gen, stored, sizeof(stored), &mon));
		CHECK(mon.species == samples[i].species);
		CHECK(!pk_nds_mon_is_empty(stored));
		printf("  %s: %s \"%s\" OT \"%s\" lv %u nature %u ability %s ball %s met %s egg=%d shiny=%d\n",
		       samples[i].file, pk_nds_species_name(mon.species), mon.nickname, mon.otName,
		       pk_nds_level(mon.species, mon.experience), mon.nature, pk_nds_ability_name(mon.ability),
		       pk_nds_ball_name(mon.ball) ? pk_nds_ball_name(mon.ball) : "?",
		       pk_nds_location_name(samples[i].gen, mon.metLocation) ? pk_nds_location_name(samples[i].gen, mon.metLocation) : "?",
		       mon.isEgg, mon.isShiny);
		if (i == 0) {
			CHECK(mon.isEgg);
			CHECK(strcmp(mon.nickname, "Oeuf") == 0 || strcmp(mon.nickname, "Œuf") == 0);
			memcpy(mon4, stored, PK_NDS_MON_SIZE);
		}
		if (i == 1) CHECK(strcmp(mon.nickname, "ROSERADE") == 0);
		if (i == 2) {
			CHECK(mon.isShiny);
			CHECK(strcmp(mon.nickname, "Haxorus") == 0);
			memcpy(mon5, stored, PK_NDS_MON_SIZE);
		}
		if (i == 3) CHECK(strchr(mon.otName, (char) 0xC3) != NULL); /* an accented letter, UTF-8 */
		/* A wrong generation is not a crash, and a damaged structure is refused. */
		stored[40] ^= 0x55;
		CHECK(!pk_nds_mon_decode(samples[i].gen, stored, sizeof(stored), &mon));
	}
	uint8_t empty[PK_NDS_MON_SIZE];
	pk_nds_empty_slot(empty);
	CHECK(pk_nds_mon_is_empty(empty));
	memset(empty, 0, sizeof(empty));
	CHECK(pk_nds_mon_is_empty(empty));
	/* Stats: a level 50 Garchomp (445) with perfect IVs and no EVs, neutral nature. */
	uint8_t ivs[6] = {31, 31, 31, 31, 31, 31}, evs[6] = {0};
	uint16_t stats[6];
	CHECK(pk_nds_calc_stats(445, ivs, evs, 50, 0, stats));
	CHECK(stats[0] == 183 && stats[1] == 150 && stats[3] == 122);
	CHECK(strcmp(pk_nds_species_name(445), "Carchacrok") == 0);
	CHECK(pk_nds_base[25].stats[2] == 30); /* Pikachu's generation 5 Defense */
	CHECK(pk_nds_base[183].type1 == 10 && pk_nds_base[183].type2 == 10); /* Marill: Water only before Fairy */
}

/* ---------- Synthetic saves ---------- */

typedef struct {
	int game;
	size_t gSize, sStart, sSize, footer, trainer, boxBase, boxStride;
} G4;

static const G4 kPt = {PK_NDS_PT, 0xCF2C, 0xCF2C, 0x121E4, 0x14, 0x68, 4, 0xFF0};
static const G4 kHGSS = {PK_NDS_HGSS, 0xF628, 0xF700, 0x12310, 0x10, 0x64, 0, 0x1000};

static void seal4(uint8_t* block, size_t size, size_t footer, uint32_t counter) {
	wr32(block + size - 0x14, counter);
	wr32(block + size - 0xC, (uint32_t) size);
	wr16(block + size - 2, crc_ref(block, size - footer));
}

static uint8_t* make_gen4(const G4* l, uint32_t newer) {
	uint8_t* sav = calloc(1, PK_NDS_SAVE_SIZE);
	for (int p = 0; p < 2; ++p) {
		uint8_t* part = sav + p * 0x40000;
		uint16_t name[] = {0x012B + 'L' - 'A', 0x0145 + 'u' - 'a', 0x0145 + 'c' - 'a', 0xFFFF}; /* "Luc" */
		for (int i = 0; i < 4; ++i) wr16(part + l->trainer + 2 * i, name[i]);
		wr16(part + l->trainer + 0x10, 12345);
		uint8_t* storage = part + l->sStart;
		for (int box = 0; box < 18; ++box)
			for (int slot = 0; slot < 30; ++slot)
				pk_nds_empty_slot(storage + l->boxBase + l->boxStride * box + PK_NDS_MON_SIZE * slot);
		uint32_t counter = (uint32_t) (p == (int) newer ? 10 : 9);
		seal4(part, l->gSize, l->footer, counter);
		seal4(storage, l->sSize, l->footer, counter);
	}
	return sav;
}

static bool storage_valid(const G4* l, const uint8_t* sav, int partition) {
	const uint8_t* s = sav + partition * 0x40000 + l->sStart;
	return crc_ref(s, l->sSize - l->footer) == rd16(s + l->sSize - 2);
}

static void test_gen4(const G4* l, const uint8_t* mon) {
	for (int newer = 0; newer < 2; ++newer) {
		uint8_t* sav = make_gen4(l, (uint32_t) newer);
		int err = -1;
		PKNDSSave* s = pk_nds_save_open(sav, PK_NDS_SAVE_SIZE, &err);
		CHECK(s && err == PK_OK);
		if (!s) {
			free(sav);
			continue;
		}
		CHECK(pk_nds_save_game(s) == l->game && pk_nds_save_generation(s) == 4);
		char name[48];
		pk_nds_save_trainer_name(s, name, sizeof(name));
		CHECK(strcmp(name, "Luc") == 0);
		CHECK(pk_nds_save_trainer_id(s) == 12345);
		CHECK(pk_nds_box_count(s) == 18);
		int box = -1, slot = -1;
		CHECK(pk_nds_first_empty(s, &box, &slot) && box == 0 && slot == 0);
		CHECK(pk_nds_put_box_mon(s, 3, 7, mon) == PK_OK);
		CHECK(pk_nds_put_box_mon(s, 3, 7, mon) == PK_ERR_OCCUPIED);
		uint8_t out[PK_NDS_SAVE_SIZE];
		CHECK(pk_nds_save_write(s, out, sizeof(out)) == PK_NDS_SAVE_SIZE);
		pk_nds_save_free(s);

		/* The mon landed in the newest partition, whose checksum is right; the other is untouched. */
		CHECK(storage_valid(l, out, newer));
		CHECK(memcmp(out + (1 - newer) * 0x40000, sav + (1 - newer) * 0x40000, 0x40000) == 0);
		const uint8_t* at = out + newer * 0x40000 + l->sStart + l->boxBase + l->boxStride * 3 + PK_NDS_MON_SIZE * 7;
		CHECK(memcmp(at, mon, PK_NDS_MON_SIZE) == 0);
		if (l->game == PK_NDS_HGSS) CHECK(rd32(out + newer * 0x40000 + l->sStart + 0x12004) == 0x3FFFF);

		s = pk_nds_save_open(out, sizeof(out), &err);
		CHECK(s != NULL);
		if (s) {
			uint8_t raw[PK_NDS_MON_SIZE];
			CHECK(pk_nds_box_mon(s, 3, 7, raw) && memcmp(raw, mon, sizeof(raw)) == 0);
			CHECK(!pk_nds_box_mon(s, 3, 8, raw));
			CHECK(pk_nds_clear_box_mon(s, 3, 7) == PK_OK);
			CHECK(!pk_nds_box_mon(s, 3, 7, raw));
			CHECK(pk_nds_box_mon(s, 18, 0, raw) == false);
			CHECK(pk_nds_put_box_mon(s, 18, 0, mon) == PK_ERR_RANGE);
			pk_nds_save_free(s);
		}

		/* A damaged newest storage block: the older copy is used instead. */
		sav[newer * 0x40000 + l->sStart + 100] ^= 1;
		s = pk_nds_save_open(sav, PK_NDS_SAVE_SIZE, &err);
		CHECK(s != NULL);
		if (s) {
			CHECK(pk_nds_put_box_mon(s, 0, 0, mon) == PK_OK);
			CHECK(pk_nds_save_write(s, out, sizeof(out)) == PK_NDS_SAVE_SIZE);
			CHECK(storage_valid(l, out, 1 - newer));
			pk_nds_save_free(s);
		}
		/* Both damaged: refused. */
		sav[(1 - newer) * 0x40000 + l->sStart + 100] ^= 1;
		s = pk_nds_save_open(sav, PK_NDS_SAVE_SIZE, &err);
		CHECK(s == NULL && err == PK_ERR_CHECKSUM);
		free(sav);
	}
}

static uint8_t* make_gen5(int game, size_t mainSize, size_t infoLength) {
	uint8_t* sav = calloc(1, PK_NDS_SAVE_SIZE);
	size_t footer = mainSize - 0x100;
	const char* boxName = "Boîte";
	(void) boxName;
	uint16_t name[] = {'E', 0xE9, 'l', 'o', 0xFFFF}; /* "Éélo": UTF-16 */
	name[0] = 0xC9;
	for (int i = 0; i < 5; ++i) wr16(sav + 0x19400 + 4 + 2 * i, name[i]);
	wr16(sav + 0x19400 + 0x14, 54321);
	uint16_t box1[] = {'P', 'C', ' ', '1', 0xFFFF};
	for (int i = 0; i < 5; ++i) wr16(sav + 4 + 2 * i, box1[i]);
	sav[0] = 2; /* current box */
	sav[0x3DD] = 8; /* boxes unlocked */
	uint16_t crc = crc_ref(sav, 0x3E0);
	wr16(sav + 0x3E2, crc);
	wr16(sav + footer, crc);
	for (int box = 0; box < 24; ++box) {
		uint8_t* data = sav + 0x400 + 0x1000 * box;
		for (int slot = 0; slot < 30; ++slot) pk_nds_empty_slot(data + PK_NDS_MON_SIZE * slot);
		crc = crc_ref(data, 0xFF0);
		wr16(data + 0xFF2, crc);
		wr16(sav + footer + 2 + 2 * box, crc);
	}
	wr16(sav + footer + infoLength + 0xE, crc_ref(sav + footer, infoLength));
	(void) game;
	return sav;
}

static void test_gen5(int game, size_t mainSize, size_t infoLength, const uint8_t* mon5, const uint8_t* mon4) {
	uint8_t* sav = make_gen5(game, mainSize, infoLength);
	size_t footer = mainSize - 0x100;
	int err = -1;
	PKNDSSave* s = pk_nds_save_open(sav, PK_NDS_SAVE_SIZE, &err);
	CHECK(s && err == PK_OK);
	if (!s) {
		free(sav);
		return;
	}
	CHECK(pk_nds_save_game(s) == game && pk_nds_save_generation(s) == 5);
	char name[48];
	pk_nds_save_trainer_name(s, name, sizeof(name));
	CHECK(strcmp(name, "\xC3\x89\xC3\xA9lo") == 0);
	CHECK(pk_nds_save_trainer_id(s) == 54321);
	CHECK(pk_nds_box_count(s) == 8);
	pk_nds_box_name(s, 0, name, sizeof(name));
	CHECK(strcmp(name, "PC 1") == 0);
	int box, slot;
	CHECK(pk_nds_first_empty(s, &box, &slot) && box == 2 && slot == 0);
	CHECK(pk_nds_put_box_mon(s, 8, 0, mon5) == PK_ERR_RANGE); /* locked box */
	CHECK(pk_nds_put_box_mon(s, 5, 29, mon5) == PK_OK);
	uint8_t out[PK_NDS_SAVE_SIZE];
	CHECK(pk_nds_save_write(s, out, sizeof(out)) == PK_NDS_SAVE_SIZE);
	pk_nds_save_free(s);

	const uint8_t* data = out + 0x400 + 0x1000 * 5;
	CHECK(memcmp(data + PK_NDS_MON_SIZE * 29, mon5, PK_NDS_MON_SIZE) == 0);
	CHECK(rd16(data + 0xFF2) == crc_ref(data, 0xFF0));
	CHECK(rd16(out + footer + 2 + 2 * 5) == crc_ref(data, 0xFF0));
	CHECK(rd16(out + footer + infoLength + 0xE) == crc_ref(out + footer, infoLength));
	/* Only box 5 and the checksum table changed. */
	size_t differing = 0;
	for (size_t i = 0; i < PK_NDS_SAVE_SIZE; ++i)
		if (out[i] != sav[i] && !(i >= 0x5400 && i < 0x6400) && !(i >= footer && i < footer + 0x100)) ++differing;
	CHECK(differing == 0);

	s = pk_nds_save_open(out, sizeof(out), &err);
	CHECK(s != NULL);
	if (s) {
		uint8_t raw[PK_NDS_MON_SIZE];
		CHECK(pk_nds_box_mon(s, 5, 29, raw) && memcmp(raw, mon5, sizeof(raw)) == 0);
		/* A generation 4 structure decodes in a generation 5 save (same format). */
		CHECK(pk_nds_put_box_mon(s, 0, 0, mon4) == PK_OK);
		pk_nds_save_free(s);
	}
	/* A damaged box block: refused. */
	out[0x400 + 10] ^= 1;
	s = pk_nds_save_open(out, sizeof(out), &err);
	CHECK(s == NULL && err == PK_ERR_CHECKSUM);
	/* Not a save at all. */
	memset(out, 0xFF, sizeof(out));
	s = pk_nds_save_open(out, sizeof(out), &err);
	CHECK(s == NULL && err == PK_ERR_NO_SLOT);
	s = pk_nds_save_open(out, 1000, &err);
	CHECK(s == NULL && err == PK_ERR_SIZE);
	free(sav);
}

int main(void) {
	uint8_t mon4[PK_NDS_MON_SIZE], mon5[PK_NDS_MON_SIZE];
	test_samples(mon4, mon5);
	test_gen4(&kPt, mon4);
	test_gen4(&kHGSS, mon4);
	/* A generation 5 Pokemon is refused by a generation 4 save. */
	uint8_t* sav = make_gen4(&kPt, 0);
	PKNDSSave* s = pk_nds_save_open(sav, PK_NDS_SAVE_SIZE, NULL);
	CHECK(s && pk_nds_put_box_mon(s, 0, 0, mon5) == PK_ERR_INVALID_MON);
	pk_nds_save_free(s);
	free(sav);
	test_gen5(PK_NDS_BW, 0x24000, 0x8C, mon5, mon4);
	test_gen5(PK_NDS_B2W2, 0x26000, 0x94, mon5, mon4);
	if (failures) {
		fprintf(stderr, "%d failure(s)\n", failures);
		return 1;
	}
	printf("pknds: all tests passed\n");
	return 0;
}
