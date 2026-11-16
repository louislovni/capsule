/* Tests for the Game Boy (generations 1 and 2) part of pkcore, on synthetic data. */
#include "pkcore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond) \
	do { \
		++checks; \
		if (!(cond)) { \
			++failures; \
			printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
		} \
	} while (0)

static void put_name(uint8_t* p, const char* ascii) {
	memset(p, 0x50, PK_GB_NAME_LENGTH);
	for (size_t i = 0; ascii[i] && i < 10; ++i) {
		p[i] = (uint8_t) (0x80 + (ascii[i] - 'A'));
	}
}

static void be16(uint8_t* p, unsigned v) {
	p[0] = (uint8_t) (v >> 8);
	p[1] = (uint8_t) v;
}

/* Bulbasaur (internal 0x99 in Red/Blue), level 5, all DVs 15. */
static void gen1_mon(uint8_t* m, size_t size, uint8_t species, uint8_t level) {
	memset(m, 0, size);
	m[0] = species;
	be16(m + 1, 19);
	m[3] = level;
	m[5] = 22;
	m[6] = 3;
	m[8] = 33;
	m[9] = 45;
	be16(m + 12, 0x1234);
	m[14] = 0;
	m[15] = 0;
	m[16] = 135;
	m[27] = 0xFF;
	m[28] = 0xFF;
	m[29] = 35 | 0x40;
	m[30] = 40;
	if (size >= PK_GB1_PARTY_MON) {
		m[33] = level;
		be16(m + 34, 21);
		be16(m + 36, 11);
		be16(m + 38, 11);
		be16(m + 40, 10);
		be16(m + 42, 12);
	}
}

/* Pikachu (25) for Gold/Silver/Crystal, DVs 10/10/10/10 (shiny). */
static void gen2_mon(uint8_t* m, size_t size, uint8_t species, uint8_t level) {
	memset(m, 0, size);
	m[0] = species;
	m[1] = 0x01;
	m[2] = 84;
	be16(m + 6, 0xBEEF);
	m[10] = 125;
	m[21] = 0xAA;
	m[22] = 0xAA;
	m[23] = 30;
	m[27] = 70;
	m[28] = 0x13;
	be16(m + 29, (2u << 14) | (4u << 8) | (1u << 7) | 3u);
	m[31] = level;
	if (size >= PK_GB2_PARTY_MON) {
		be16(m + 34, 18);
		be16(m + 36, 20);
		for (int i = 0; i < 5; ++i) {
			be16(m + 38 + i * 2, 10);
		}
	}
}

static void test_text_and_mon(void) {
	uint8_t text[] = { 0x8B, 0x8E, 0x94, 0x88, 0x92, 0x7F, 0xBC, 0xF7, 0xEF, 0x50, 0x80 };
	char out[PK_TEXT_UTF8];
	pk_gb_text_decode(text, sizeof(text), out, sizeof(out));
	CHECK(strcmp(out, "LOUIS é1♂") == 0);

	uint8_t m[PK_GB1_PARTY_MON], ot[11], nick[11];
	put_name(ot, "RED");
	put_name(nick, "BULBI");
	gen1_mon(m, sizeof(m), 0x99, 5);
	PKGBMon mon;
	CHECK(pk_gb_mon_decode(1, m, PK_GB1_BOX_MON, ot, nick, 0x99, &mon));
	CHECK(mon.dex == 1 && mon.level == 5 && mon.hp == 19 && !mon.hasPartyData);
	CHECK(mon.moves[0] == 33 && mon.pp[0] == 35 && mon.ppUps[0] == 1 && mon.otId == 0x1234 && mon.experience == 135);
	CHECK(mon.dvs[0] == 15 && mon.dvs[1] == 15 && mon.dvs[4] == 15 && !mon.isShiny);
	CHECK(strcmp(mon.otName, "RED") == 0 && strcmp(mon.nickname, "BULBI") == 0);
	CHECK(pk_gb_mon_decode(1, m, sizeof(m), ot, nick, 0x99, &mon) && mon.hasPartyData && mon.stats[0] == 21 && mon.stats[5] == 12);
	m[0] = 0x1F; /* a glitch index */
	CHECK(!pk_gb_mon_decode(1, m, PK_GB1_BOX_MON, ot, nick, 0x1F, &mon));

	uint16_t stats[6];
	uint8_t dvs[5] = { 15, 15, 15, 15, 15 };
	uint16_t zero[5] = { 0 };
	pk_gb_calc_stats(1, 1, dvs, zero, 5, stats);
	CHECK(stats[0] == 21 && stats[1] == 11 && stats[2] == 11 && stats[3] == 11 && stats[4] == 13 && stats[5] == 13);
	/* Level 100 Mewtwo, Gen 2, max DVs and stat experience (worth +63): 415 HP, 358 Spe, 406 SpA, 278 SpD */
	uint16_t full[5] = { 65535, 65535, 65535, 65535, 65535 };
	pk_gb_calc_stats(2, 150, dvs, full, 100, stats);
	CHECK(stats[0] == 415 && stats[3] == 358 && stats[4] == 406 && stats[5] == 278);

	uint8_t g2[PK_GB2_PARTY_MON];
	gen2_mon(g2, sizeof(g2), 25, 12);
	CHECK(pk_gb_mon_decode(2, g2, sizeof(g2), ot, nick, 25, &mon));
	CHECK(mon.dex == 25 && mon.isShiny && mon.heldItem == 1 && mon.friendship == 70 && mon.pokerus == 0x13);
	CHECK(mon.hasCaughtData && mon.metTime == 2 && mon.metLevel == 4 && mon.otGender == 1 && mon.metLocation == 3);
	CHECK(mon.hasPartyData && mon.hp == 18 && mon.stats[0] == 20);
	CHECK(pk_gb_gender(25, mon.dvs) == 0);
	uint8_t lowAtk[5] = { 0, 2, 0, 3, 0 };
	CHECK(pk_gb_gender(25, lowAtk) == 1);
	CHECK(pk_gb_gender(81, lowAtk) == 2); /* Magnemite */
	uint8_t type, power;
	pk_gb_hidden_power(dvs, &type, &power);
	CHECK(type == 15 && power == 70);
	CHECK(pk_gb_mon_decode(2, g2, PK_GB2_BOX_MON, ot, nick, 0xFD, &mon) && mon.isEgg);

	CHECK(strcmp(pk_gb_species_names[25], "Pikachu") == 0);
	CHECK(pk_gb_landmark_count > 90);
}

static void test_scan(void) {
	enum { RAM = 0x2000 };
	uint8_t* ram = malloc(RAM);
	for (int i = 0; i < RAM; ++i) {
		ram[i] = (uint8_t) (i * 13 + 7);
	}
	int count = 0;
	CHECK(pk_gb_scan_party(ram, RAM, 1, &count) == -1);
	size_t at = 0x1163;
	ram[at] = 2;
	ram[at + 1] = 0x99;
	ram[at + 2] = 0x99;
	ram[at + 3] = 0xFF;
	gen1_mon(ram + at + 8, PK_GB1_PARTY_MON, 0x99, 5);
	gen1_mon(ram + at + 8 + PK_GB1_PARTY_MON, PK_GB1_PARTY_MON, 0x99, 7);
	CHECK(pk_gb_scan_party(ram, RAM, 1, &count) == (long) at && count == 2);
	CHECK(pk_gb_scan_party(ram, RAM, 2, &count) == -1);
	free(ram);
}

static void init_box(uint8_t* box) {
	box[0] = 0;
	box[1] = 0xFF;
}

static uint8_t gen1_sum(const uint8_t* d, size_t start, size_t length) {
	uint8_t s = 0;
	for (size_t i = 0; i < length; ++i) {
		s = (uint8_t) (s + d[start + i]);
	}
	return (uint8_t) ~s;
}

static void test_gen1_save(void) {
	enum { SIZE = 0x8000 };
	uint8_t* d = calloc(1, SIZE);
	put_name(d + 0x2598, "LOUIS");
	be16(d + 0x2605, 4242);
	d[0x284C] = 0x80 | 2; /* boxes set up, current box 3 */
	d[0x2F2C] = 0;
	d[0x2F2D] = 0xFF;
	init_box(d + 0x30C0);
	for (int i = 0; i < 6; ++i) {
		init_box(d + 0x4000 + i * 0x462);
		init_box(d + 0x6000 + i * 0x462);
	}
	/* a Bulbasaur in the active box (box 3) */
	uint8_t* box = d + 0x30C0;
	box[0] = 1;
	box[1] = 0x99;
	box[2] = 0xFF;
	gen1_mon(box + 22, PK_GB1_BOX_MON, 0x99, 5);
	put_name(box + 22 + 20 * 33, "RED");
	put_name(box + 22 + 20 * 33 + 220, "BULBI");
	d[0x3523] = gen1_sum(d, 0x2598, 0x3523 - 0x2598);

	int err = -1;
	PKGBSave* save = pk_gb_save_open(d, SIZE, &err);
	CHECK(save && err == PK_OK);
	if (!save) {
		free(d);
		return;
	}
	CHECK(pk_gb_save_game(save) == PK_GB_GEN1 && pk_gb_save_generation(save) == 1);
	char name[PK_TEXT_UTF8];
	pk_gb_save_trainer_name(save, name, sizeof(name));
	CHECK(strcmp(name, "LOUIS") == 0 && pk_gb_save_trainer_id(save) == 4242);
	CHECK(pk_gb_box_count(save) == 12 && pk_gb_current_box(save) == 2);
	CHECK(pk_gb_box_size(save, 2) == 1 && pk_gb_box_size(save, 0) == 0 && pk_gb_box_usable(save, 7));
	uint8_t blob[PK_GB1_BLOB];
	CHECK(pk_gb_blob_size(save) == PK_GB1_BLOB);
	CHECK(pk_gb_box_mon(save, 2, 0, blob));
	PKGBMon mon;
	CHECK(pk_gb_blob_decode(1, blob, sizeof(blob), &mon) && mon.dex == 1 && strcmp(mon.nickname, "BULBI") == 0);
	CHECK(!pk_gb_box_mon(save, 2, 1, blob) && !pk_gb_box_mon(save, 0, 0, blob));

	/* move it from the active box to box 8 (bank 3) */
	CHECK(pk_gb_box_append(save, 7, blob, sizeof(blob)) == PK_OK);
	CHECK(pk_gb_box_remove(save, 2, 0) == PK_OK);
	CHECK(pk_gb_box_size(save, 2) == 0 && pk_gb_box_size(save, 7) == 1);
	int freeBox = -1;
	CHECK(pk_gb_first_free(save, &freeBox) && freeBox == 2);
	uint8_t bad[PK_GB1_BLOB];
	memcpy(bad, blob, sizeof(bad));
	bad[0] = 0x1F;
	CHECK(pk_gb_box_append(save, 0, bad, sizeof(bad)) == PK_ERR_INVALID_MON);

	uint8_t* out = malloc(SIZE);
	CHECK(pk_gb_save_write(save, out, SIZE) == SIZE);
	pk_gb_save_free(save);
	CHECK(out[0x3523] == gen1_sum(out, 0x2598, 0x3523 - 0x2598));
	CHECK(out[0x7A4C] == gen1_sum(out, 0x6000, 0x1A4C));
	CHECK(out[0x7A4D + 1] == gen1_sum(out, 0x6000 + 0x462, 0x462));
	CHECK(memcmp(out + 0x4000, d + 0x4000, 0x2000) == 0); /* bank 2 untouched */
	save = pk_gb_save_open(out, SIZE, &err);
	CHECK(save != NULL);
	if (save) {
		CHECK(pk_gb_box_mon(save, 7, 0, blob) && pk_gb_blob_decode(1, blob, sizeof(blob), &mon) && mon.level == 5);
		pk_gb_save_free(save);
	}

	/* boxes never set up: only the active one is usable */
	d[0x284C] = 2;
	d[0x3523] = gen1_sum(d, 0x2598, 0x3523 - 0x2598);
	save = pk_gb_save_open(d, SIZE, &err);
	CHECK(save && !pk_gb_box_usable(save, 7) && pk_gb_box_usable(save, 2));
	CHECK(save && pk_gb_box_append(save, 7, blob, sizeof(blob)) == PK_ERR_RANGE);
	pk_gb_save_free(save);

	d[0x3000] ^= 1; /* broken checksum */
	CHECK(pk_gb_save_open(d, SIZE, &err) == NULL);
	free(out);
	free(d);
}

static void test_crystal_save(void) {
	enum { SIZE = 0x8000 };
	uint8_t* d = calloc(1, SIZE);
	be16(d + 0x2009, 777);
	put_name(d + 0x200B, "GOLD");
	d[0x2700] = 0;
	put_name(d + 0x2703, "BOITE");
	d[0x2865] = 0;
	d[0x2866] = 0xFF;
	init_box(d + 0x2D10);
	for (int i = 0; i < 7; ++i) {
		init_box(d + 0x4000 + i * 0x450);
		init_box(d + 0x6000 + i * 0x450);
	}
	uint16_t sum = 0;
	for (int i = 0x2009; i <= 0x2B82; ++i) {
		sum = (uint16_t) (sum + d[i]);
	}
	d[0x2D0D] = (uint8_t) sum;
	d[0x2D0E] = (uint8_t) (sum >> 8);

	int err = -1;
	PKGBSave* save = pk_gb_save_open(d, SIZE, &err);
	CHECK(save && pk_gb_save_game(save) == PK_GB_CRYSTAL && pk_gb_box_count(save) == 14);
	if (!save) {
		free(d);
		return;
	}
	char name[PK_TEXT_UTF8];
	pk_gb_box_name(save, 0, name, sizeof(name));
	CHECK(strcmp(name, "BOITE") == 0);
	uint8_t blob[PK_GB2_BLOB];
	gen2_mon(blob, PK_GB2_BOX_MON, 25, 12);
	put_name(blob + 32, "GOLD");
	put_name(blob + 43, "PIKA");
	blob[54] = 25;
	CHECK(pk_gb_box_append(save, 0, blob, sizeof(blob)) == PK_OK);
	CHECK(pk_gb_box_append(save, 13, blob, sizeof(blob)) == PK_OK);
	uint8_t* out = malloc(SIZE);
	CHECK(pk_gb_save_write(save, out, SIZE) == SIZE);
	pk_gb_save_free(save);
	CHECK(out[0x2D10] == 1 && out[0x2D11] == 25 && out[0x2D12] == 0xFF);
	CHECK(out[0x6000 + 6 * 0x450] == 1);
	CHECK(memcmp(out + 0x2009, d + 0x2009, 0x2B83 - 0x2009) == 0); /* main data and its checksum untouched */
	save = pk_gb_save_open(out, SIZE, &err);
	CHECK(save != NULL);
	if (save) {
		uint8_t back[PK_GB2_BLOB];
		PKGBMon mon;
		CHECK(pk_gb_box_mon(save, 13, 0, back) && pk_gb_blob_decode(2, back, sizeof(back), &mon) &&
		      mon.isShiny && strcmp(mon.nickname, "PIKA") == 0);
		pk_gb_save_free(save);
	}
	free(out);
	free(d);
}

int main(void) {
	test_text_and_mon();
	test_scan();
	test_gen1_save();
	test_crystal_save();
	printf("%d checks, %d failures\n", checks, failures);
	return failures ? 1 : 0;
}
