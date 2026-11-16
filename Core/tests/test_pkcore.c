/* Unit tests for pkcore, built from synthetic data only (no game data needed).
 * Build and run: make -C Core/tests
 */
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

static void wr16(uint8_t* p, uint16_t v) {
	p[0] = (uint8_t) v;
	p[1] = (uint8_t) (v >> 8);
}

static void wr32(uint8_t* p, uint32_t v) {
	p[0] = (uint8_t) v;
	p[1] = (uint8_t) (v >> 8);
	p[2] = (uint8_t) (v >> 16);
	p[3] = (uint8_t) (v >> 24);
}

static uint32_t rd32(const uint8_t* p) {
	return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

/* Independent encoder: letter order written out by name, not shared with pk_mon.c. */
static const char* const kOrderNames[24] = { "GAEM", "GAME", "GEAM", "GEMA", "GMAE", "GMEA", "AGEM", "AGME",
	                                         "AEGM", "AEMG", "AMGE", "AMEG", "EGAM", "EGMA", "EAGM", "EAMG",
	                                         "EMGA", "EMAG", "MGAE", "MGEA", "MAGE", "MAEG", "MEGA", "MEAG" };

static void make_mon(uint8_t* raw, size_t rawSize, uint32_t personality, uint32_t otId, uint16_t species,
                     uint8_t level) {
	memset(raw, 0, rawSize);
	wr32(raw, personality);
	wr32(raw + 4, otId);
	/* nickname "PIKA" */
	const uint8_t nick[] = { 0xCA, 0xC3, 0xC5, 0xBB, 0xFF };
	memset(raw + 8, 0xFF, 10);
	memcpy(raw + 8, nick, sizeof(nick));
	raw[18] = 5; /* French */
	raw[19] = 0x02; /* has species */
	const uint8_t ot[] = { 0xC6, 0xC9, 0xCF, 0xC3, 0xCD, 0xFF, 0xFF }; /* LOUIS */
	memcpy(raw + 20, ot, 7);

	uint8_t growth[12] = { 0 }, attacks[12] = { 0 }, evs[12] = { 0 }, misc[12] = { 0 };
	wr16(growth, species);
	wr16(growth + 2, 0x00C5);
	wr32(growth + 4, 123456);
	growth[9] = 70;
	wr16(attacks, 33);
	wr16(attacks + 2, 45);
	wr16(attacks + 4, 84);
	wr16(attacks + 6, 98);
	attacks[8] = 35;
	attacks[9] = 40;
	attacks[10] = 30;
	attacks[11] = 30;
	for (int i = 0; i < 6; ++i) {
		evs[i] = (uint8_t) (10 + i);
	}
	misc[1] = 16;
	wr16(misc + 2, (uint16_t) (5 | (3 << 7) | (4 << 11)));
	wr32(misc + 4, 31u | (30u << 5) | (29u << 10) | (28u << 15) | (27u << 20) | (26u << 25) | (1u << 31));

	uint8_t data[48];
	const char* order = kOrderNames[personality % 24];
	for (int i = 0; i < 4; ++i) {
		const uint8_t* src = order[i] == 'G' ? growth : order[i] == 'A' ? attacks : order[i] == 'E' ? evs : misc;
		memcpy(data + i * 12, src, 12);
	}
	uint16_t sum = 0;
	for (int i = 0; i < 48; i += 2) {
		sum = (uint16_t) (sum + (data[i] | (data[i + 1] << 8)));
	}
	wr16(raw + 28, sum);
	uint32_t key = personality ^ otId;
	for (int i = 0; i < 48; i += 4) {
		wr32(raw + 32 + i, rd32(data + i) ^ key);
	}
	if (rawSize >= PK_PARTY_MON_SIZE) {
		wr32(raw + 80, 0x08); /* poisoned */
		raw[84] = level;
		wr16(raw + 86, 12);
		wr16(raw + 88, 40);
		wr16(raw + 90, 21);
		wr16(raw + 92, 22);
		wr16(raw + 94, 23);
		wr16(raw + 96, 24);
		wr16(raw + 98, 25);
	}
}

static void test_text(void) {
	const uint8_t in[] = { 0xBC, 0xCF, 0xC6, 0xBC, 0xC3, 0xD4, 0xBB, 0xCC, 0xCC, 0xBF, 0xFF, 0xBB };
	char out[PK_TEXT_UTF8];
	pk_text_decode(in, sizeof(in), out, sizeof(out));
	CHECK(strcmp(out, "BULBIZARRE") == 0);
	const uint8_t accents[] = { 0xCA, 0xC9, 0xC5, 0x1B, 0xC7, 0xC9, 0xC8, 0x00, 0xA1, 0xAA, 0xB5, 0xFF };
	pk_text_decode(accents, sizeof(accents), out, sizeof(out));
	CHECK(strcmp(out, "POKéMON 09♂") == 0);
	char tiny[4];
	pk_text_decode(in, sizeof(in), tiny, sizeof(tiny));
	CHECK(strcmp(tiny, "BUL") == 0);
}

static void test_mon(void) {
	for (uint32_t i = 0; i < 24; ++i) {
		uint8_t raw[PK_PARTY_MON_SIZE];
		uint32_t personality = 0x12345600u + i; /* 24 consecutive values cover every substructure order */
		make_mon(raw, sizeof(raw), personality, 0xABCD1234u, (uint16_t) (25 + i), 17);
		PKMon mon;
		CHECK(pk_mon_decode(raw, sizeof(raw), &mon));
		CHECK(mon.species == 25 + i);
		CHECK(mon.heldItem == 0xC5);
		CHECK(mon.experience == 123456);
		CHECK(mon.friendship == 70);
		CHECK(mon.moves[0] == 33 && mon.moves[1] == 45 && mon.moves[2] == 84 && mon.moves[3] == 98);
		CHECK(mon.pp[0] == 35 && mon.pp[3] == 30);
		CHECK(mon.evs[0] == 10 && mon.evs[5] == 15);
		CHECK(mon.ivs[0] == 31 && mon.ivs[1] == 30 && mon.ivs[5] == 26);
		CHECK(mon.abilityBit == 1);
		CHECK(mon.metLevel == 5 && mon.originGame == 3 && mon.ball == 4 && mon.metLocation == 16);
		CHECK(strcmp(mon.nickname, "PIKA") == 0);
		CHECK(strcmp(mon.otName, "LOUIS") == 0);
		CHECK(mon.hasPartyData && mon.level == 17 && mon.hp == 12 && mon.maxHp == 40 && mon.status == 8);
		CHECK(!mon.isShiny && !mon.isEgg);

		/* a flipped bit must break the checksum */
		raw[40] ^= 0x10;
		CHECK(!pk_mon_decode(raw, sizeof(raw), &mon));
		raw[40] ^= 0x10;

		CHECK(pk_party_heal(raw));
		CHECK(pk_mon_decode(raw, sizeof(raw), &mon));
		CHECK(mon.hp == 40 && mon.status == 0);
	}
	uint8_t shiny[PK_BOX_MON_SIZE];
	make_mon(shiny, sizeof(shiny), 0x00010003u, 0x00020001u, 1, 5); /* 2^1^1^3 = 1 < 8 */
	PKMon mon;
	CHECK(pk_mon_decode(shiny, sizeof(shiny), &mon));
	CHECK(mon.isShiny && !mon.hasPartyData);

	uint8_t empty[PK_BOX_MON_SIZE] = { 0 };
	CHECK(pk_mon_is_empty(empty));
	CHECK(!pk_mon_is_empty(shiny));
	CHECK(!pk_mon_decode(empty, sizeof(empty), &mon));
}

#define SECTION 0x1000

static uint16_t ref_checksum(const uint8_t* d, size_t n) {
	uint32_t sum = 0;
	for (size_t i = 0; i < n; i += 4) {
		sum += rd32(d + i);
	}
	return (uint16_t) ((sum >> 16) + sum);
}

/* Builds a slot whose sections are rotated by `rotation`, as the games do. */
static void build_slot(uint8_t* slotBase, int rotation, uint32_t counter, const uint8_t* pc, uint32_t gameCode) {
	static const size_t sizes[14] = { 3884, 3968, 3968, 3968, 3848, 3968, 3968, 3968, 3968, 3968, 3968, 3968, 3968, 2000 };
	size_t pcOffset = 0;
	for (int id = 0; id < 14; ++id) {
		uint8_t* s = slotBase + (size_t) ((id + rotation) % 14) * SECTION;
		memset(s, 0, SECTION);
		if (id == 0) {
			const uint8_t name[] = { 0xC6, 0xC9, 0xCF, 0xC3, 0xCD, 0xFF, 0xFF, 0xFF };
			memcpy(s, name, 8);
			wr32(s + 0x0A, 0xBEEF1234u);
			wr16(s + 0x0E, 42);
			s[0x10] = 7;
			wr32(s + 0xAC, gameCode);
		} else if (id >= 5) {
			memcpy(s, pc + pcOffset, sizes[id]);
			pcOffset += sizes[id];
		} else {
			for (size_t i = 0; i < sizes[id]; ++i) {
				s[i] = (uint8_t) (i * 7 + id);
			}
		}
		wr16(s + 0xFF4, (uint16_t) id);
		wr16(s + 0xFF6, ref_checksum(s, sizes[id]));
		wr32(s + 0xFF8, 0x08012025u);
		wr32(s + 0xFFC, counter);
	}
}

static void test_save(void) {
	enum { SIZE = 0x20000 };
	uint8_t* file = malloc(SIZE);
	uint8_t* pc = calloc(1, 33744);
	memset(file, 0xFF, SIZE);

	/* Box 3 is called "BOITE 4"; one Pokemon in box 0 slot 0 and one in box 13 slot 29. */
	const uint8_t boxName[] = { 0xBC, 0xC9, 0xC3, 0xCE, 0xBF, 0x00, 0xA5, 0xFF, 0xFF };
	memcpy(pc + 4 + 420 * 80 + 3 * 9, boxName, 9);
	uint8_t monA[80], monB[80], monC[80];
	make_mon(monA, 80, 0x1111, 0x2222, 280, 0);
	make_mon(monB, 80, 0x3334, 0x4444, 150, 0);
	make_mon(monC, 80, 0x5557, 0x6666, 6, 0);
	memcpy(pc + 4, monA, 80);
	memcpy(pc + 4 + (13 * 30 + 29) * 80, monB, 80);

	build_slot(file, 3, 10, pc, 1); /* older copy in slot 0 */
	build_slot(file + 14 * SECTION, 9, 11, pc, 1); /* newer copy in slot 1 */
	int err = -1;
	PKSave* save = pk_save_open(file, SIZE, &err);
	CHECK(save != NULL && err == PK_OK);
	if (!save) {
		return;
	}
	CHECK(pk_save_game(save) == PK_GAME_FRLG);
	char text[PK_TEXT_UTF8];
	pk_save_trainer_name(save, text, sizeof(text));
	CHECK(strcmp(text, "LOUIS") == 0);
	CHECK(pk_save_trainer_id(save) == 0xBEEF1234u);
	CHECK(pk_save_play_time(save) == ((42u << 16) | 7));
	pk_save_box_name(save, 3, text, sizeof(text));
	CHECK(strcmp(text, "BOITE 4") == 0);

	PKMon mon;
	CHECK(pk_mon_decode(pk_save_box_mon(save, 0, 0), 80, &mon) && mon.species == 280);
	CHECK(pk_mon_decode(pk_save_box_mon(save, 13, 29), 80, &mon) && mon.species == 150);
	CHECK(pk_mon_is_empty(pk_save_box_mon(save, 0, 1)));
	CHECK(pk_save_box_mon(save, 14, 0) == NULL && pk_save_box_mon(save, 0, 30) == NULL);

	int box = -1, slot = -1;
	CHECK(pk_save_first_empty(save, &box, &slot) && box == 0 && slot == 1);
	CHECK(pk_save_put_box_mon(save, 0, 0, monC) == PK_ERR_OCCUPIED);
	uint8_t broken[80];
	memcpy(broken, monC, 80);
	broken[50] ^= 1;
	CHECK(pk_save_put_box_mon(save, 0, 1, broken) == PK_ERR_INVALID_MON);
	CHECK(pk_save_put_box_mon(save, 0, 1, monC) == PK_OK);
	CHECK(pk_save_clear_box_mon(save, 13, 29) == PK_OK);

	uint8_t* out = malloc(SIZE);
	CHECK(pk_save_write(save, out, SIZE - 1) == 0);
	CHECK(pk_save_write(save, out, SIZE) == SIZE);
	pk_save_free(save);

	/* The older slot and every non-PC section of the active slot are untouched. */
	CHECK(memcmp(out, file, 14 * SECTION) == 0);
	int changedSections = 0;
	for (int i = 0; i < 14; ++i) {
		const uint8_t* a = file + (14 + i) * SECTION;
		const uint8_t* b = out + (14 + i) * SECTION;
		uint16_t id = (uint16_t) (a[0xFF4] | (a[0xFF5] << 8));
		if (memcmp(a, b, SECTION) != 0) {
			++changedSections;
			CHECK(id >= 5);
		}
		/* footer id / signature / counter never change */
		CHECK(memcmp(a + 0xFF4, b + 0xFF4, 2) == 0 && memcmp(a + 0xFF8, b + 0xFF8, 8) == 0);
	}
	CHECK(changedSections == 2); /* section 5 (box 0) and section 13 (box 13 tail) */

	/* Re-open: checksums are valid again and the changes are there. */
	save = pk_save_open(out, SIZE, &err);
	CHECK(save != NULL && err == PK_OK);
	if (save) {
		CHECK(pk_mon_decode(pk_save_box_mon(save, 0, 1), 80, &mon) && mon.species == 6);
		CHECK(pk_mon_is_empty(pk_save_box_mon(save, 13, 29)));
		CHECK(pk_mon_decode(pk_save_box_mon(save, 0, 0), 80, &mon) && mon.species == 280);
		pk_save_free(save);
	}

	/* Slot choice: bump the counter of slot 0 above slot 1 and wipe a mon there. */
	memset(pc + 4, 0, 80);
	build_slot(file, 0, 12, pc, 0);
	save = pk_save_open(file, SIZE, &err);
	CHECK(save != NULL);
	if (save) {
		CHECK(pk_save_game(save) == PK_GAME_RS);
		CHECK(pk_mon_is_empty(pk_save_box_mon(save, 0, 0)));
		pk_save_free(save);
	}

	/* Only one slot written (fresh game): the other one is all 0xFF. */
	memset(file + 14 * SECTION, 0xFF, 14 * SECTION);
	save = pk_save_open(file, SIZE, &err);
	CHECK(save != NULL);
	pk_save_free(save);

	/* Corrupt PC section -> refused. */
	file[5 * SECTION + 100] ^= 0x55;
	save = pk_save_open(file, SIZE, &err);
	CHECK(save == NULL && err == PK_ERR_CHECKSUM);

	/* Garbage and short files -> refused. */
	memset(file, 0xFF, SIZE);
	CHECK(pk_save_open(file, SIZE, &err) == NULL && err == PK_ERR_NO_SLOT);
	CHECK(pk_save_open(file, 0x10000, &err) == NULL && err == PK_ERR_SIZE);

	free(out);
	free(pc);
	free(file);
}

static void test_live(void) {
	const PKProfile* p = pk_profile_find("BPEF", 0);
	CHECK(p && p->playerParty == 0x020244EC && p->playerPartyCount == 0x020244E9);
	p = pk_profile_find("BPRF", 0);
	CHECK(p && p->playerParty == 0x02024284 && p->saveBlock1Ptr == 0x03004F58);
	p = pk_profile_find("BPRE", 7); /* unknown revision -> same code */
	CHECK(p && memcmp(p->code, "BPRE", 4) == 0);
	CHECK(pk_profile_find("ZZZZ", 0) == NULL);

	enum { RAM = 0x40000 };
	uint8_t* ram = malloc(RAM);
	srand(1234);
	for (int i = 0; i < RAM; ++i) {
		ram[i] = (uint8_t) rand();
	}
	int count = 0;
	CHECK(pk_scan_party(ram, RAM, &count) == -1);
	for (int i = 0; i < 3; ++i) {
		make_mon(ram + 0x244EC + i * 100, 100, 0x777u + (uint32_t) i, 0x999, (uint16_t) (1 + i), (uint8_t) (5 + i));
	}
	memset(ram + 0x244EC + 300, 0, 300);
	CHECK(pk_scan_party(ram, RAM, &count) == 0x244EC);
	CHECK(count == 3);
	free(ram);

	/* ROM name tables */
	enum { ROM = 0x80000 };
	uint8_t* rom = malloc(ROM);
	for (int i = 0; i < ROM; ++i) {
		rom[i] = (uint8_t) rand();
	}
	/* decoy: the first entry alone, followed by noise */
	memset(rom + 0x100, 0xAC, 10);
	rom[0x10A] = 0xFF;
	memset(rom + 0x10B, 0x77, 64);
	long speciesAt = 0x30000;
	for (int i = 0; i < 412; ++i) {
		uint8_t* e = rom + speciesAt + i * 11;
		memset(e, 0, 11);
		if (i == 0) {
			memset(e, 0xAC, 10);
			e[10] = 0xFF;
		} else {
			e[0] = (uint8_t) (0xBB + (i % 26));
			e[1] = (uint8_t) (0xBB + ((i / 26) % 26));
			e[2] = 0xFF;
		}
	}
	long movesAt = 0x50000;
	for (int i = 0; i < 355; ++i) {
		uint8_t* e = rom + movesAt + i * 13;
		memset(e, 0, 13);
		if (i == 0) {
			e[0] = 0xAE;
			e[1] = 0xFF;
		} else {
			e[0] = (uint8_t) (0xBB + (i % 26));
			e[1] = 0xFF;
		}
	}
	CHECK(pk_rom_find_species_names(rom, ROM) == speciesAt);
	CHECK(pk_rom_find_move_names(rom, ROM) == movesAt);
	char name[PK_TEXT_UTF8];
	pk_rom_table_name(rom, ROM, speciesAt, PK_SPECIES_NAME_STRIDE, 27, name, sizeof(name));
	CHECK(strcmp(name, "BB") == 0);
	pk_rom_table_name(rom, ROM, movesAt, PK_MOVE_NAME_STRIDE, 3, name, sizeof(name));
	CHECK(strcmp(name, "D") == 0);
	pk_rom_table_name(rom, ROM, speciesAt, PK_SPECIES_NAME_STRIDE, 999999, name, sizeof(name));
	CHECK(name[0] == '\0');
	CHECK(pk_rom_find_species_names(rom, 0x1000) == -1);
	free(rom);
}

static void put_text(uint8_t* p, const char* ascii) {
	/* uppercase ASCII letters, digits and spaces only */
	for (; *ascii; ++ascii, ++p) {
		char c = *ascii;
		*p = c == ' ' ? 0x00 : (c >= '0' && c <= '9') ? (uint8_t) (0xA1 + c - '0') : (uint8_t) (0xBB + c - 'A');
	}
	*p = 0xFF;
}

static void test_info(void) {
	/* Experience curves: level 100 totals and a few boundaries. */
	CHECK(pk_exp_for_level(0, 100) == 1000000);
	CHECK(pk_exp_for_level(1, 100) == 600000);
	CHECK(pk_exp_for_level(2, 100) == 1640000);
	CHECK(pk_exp_for_level(3, 100) == 1059860);
	CHECK(pk_exp_for_level(4, 100) == 800000);
	CHECK(pk_exp_for_level(5, 100) == 1250000);
	CHECK(pk_exp_for_level(1, 50) == 125000 && pk_exp_for_level(1, 68) == 257834 && pk_exp_for_level(1, 98) == 583539);
	CHECK(pk_exp_for_level(2, 15) == 1957 && pk_exp_for_level(2, 36) == 46656);
	CHECK(pk_exp_for_level(3, 1) == 0 && pk_exp_for_level(3, 2) == 9 && pk_exp_for_level(3, 5) == 135);
	CHECK(pk_level_for_exp(3, 135) == 5 && pk_level_for_exp(3, 134) == 4 && pk_level_for_exp(3, 0) == 1);
	CHECK(pk_level_for_exp(0, 2000000) == 100);
	for (uint8_t g = 0; g <= 5; ++g) {
		for (unsigned l = 2; l <= 100; ++l) {
			CHECK(pk_exp_for_level(g, l) > pk_exp_for_level(g, l - 1));
			CHECK(pk_level_for_exp(g, pk_exp_for_level(g, l)) == l);
		}
	}

	/* Bulbapedia's worked example: level 78 Garchomp, Adamant. */
	PKBaseStats garchomp = { .baseStats = { 108, 130, 95, 102, 80, 85 } };
	uint8_t ivs[6] = { 24, 12, 30, 5, 16, 23 };
	uint8_t evs[6] = { 74, 190, 91, 23, 48, 84 };
	uint16_t stats[6];
	pk_calc_stats(&garchomp, ivs, evs, 78, 3, 445, stats);
	CHECK(stats[0] == 289 && stats[1] == 278 && stats[2] == 193 && stats[3] == 171 && stats[4] == 135 && stats[5] == 171);
	pk_calc_stats(&garchomp, ivs, evs, 78, 3, 303, stats);
	CHECK(stats[0] == 1);
	int up, down;
	pk_nature_effect(3, &up, &down);
	CHECK(up == 0 && down == 3);
	pk_nature_effect(12, &up, &down);
	CHECK(up == -1 && down == -1);

	CHECK(pk_gender(0x100, 0) == 0 && pk_gender(0x1FF, 254) == 1 && pk_gender(0, 255) == 2);
	CHECK(pk_gender(0x1E, 31) == 1 && pk_gender(0x1F, 31) == 0);
	CHECK(pk_ribbon_count(0) == 0);
	CHECK(pk_ribbon_count(4u | (1u << 15) | (1u << 26) | (1u << 31)) == 6);

	uint8_t raw[PK_BOX_MON_SIZE];
	make_mon(raw, sizeof(raw), 0x1111, 0x2222, 280, 0);
	PKMon mon;
	CHECK(pk_mon_decode(raw, sizeof(raw), &mon));
	CHECK(mon.nature == 0x1111 % 25);
	CHECK(mon.hiddenPowerType == 5 && mon.hiddenPowerPower == 62);

	/* ROM tables, laid out in a synthetic ROM. */
	enum { ROM = 0x100000 };
	uint8_t* rom = calloc(1, ROM);
	for (int i = 0; i < ROM; ++i) {
		rom[i] = (uint8_t) (i * 37 + 11);
	}
	/* base stats: 412 entries of 28 bytes */
	long baseAt = 0x10000;
	memset(rom + baseAt, 0, 28 * 412);
	const uint8_t bulba[24] = { 45, 49, 49, 45, 65, 65, 12, 3, 45, 64, 0, 1, 0, 0, 0, 0, 31, 20, 70, 3, 1, 7, 65, 0 };
	memcpy(rom + baseAt + 28, bulba, sizeof(bulba));
	CHECK(pk_rom_find_base_stats(rom, ROM) == baseAt);
	PKBaseStats bs;
	CHECK(pk_rom_base_stats(rom, ROM, baseAt, 1, &bs));
	CHECK(bs.baseStats[5] == 65 && bs.type1 == 12 && bs.genderRatio == 31 && bs.growthRate == 3 && bs.ability1 == 65);
	CHECK(!pk_rom_base_stats(rom, ROM, baseAt, 2, &bs)); /* all zero */
	CHECK(!pk_rom_base_stats(rom, ROM, baseAt, 0, &bs));

	/* national dex: species 1..411 */
	long dexAt = 0x20002;
	for (unsigned i = 0; i < 411; ++i) {
		unsigned v = i < 251 ? i + 1 : (i < 276 ? 387 : 252 + (i - 276));
		rom[dexAt + i * 2] = (uint8_t) v;
		rom[dexAt + i * 2 + 1] = (uint8_t) (v >> 8);
	}
	CHECK(pk_rom_find_national_dex(rom, ROM) == dexAt);
	CHECK(pk_rom_national_dex(rom, ROM, dexAt, 25) == 25);
	CHECK(pk_rom_national_dex(rom, ROM, dexAt, 277) == 252);
	CHECK(pk_rom_national_dex(rom, ROM, dexAt, 260) == 0);

	/* abilities: 78 x 13 */
	long abilityAt = 0x30001;
	memset(rom + abilityAt, 0, 13 * 78);
	memset(rom + abilityAt, 0xAE, 7);
	rom[abilityAt + 7] = 0xFF;
	for (int i = 1; i < 78; ++i) {
		put_text(rom + abilityAt + i * 13, i == 65 ? "ENGRAIS" : "TALENT");
	}
	CHECK(pk_rom_find_ability_names(rom, ROM) == abilityAt);
	char text[PK_TEXT_UTF8];
	pk_rom_table_name(rom, ROM, abilityAt, PK_ABILITY_NAME_STRIDE, 65, text, sizeof(text));
	CHECK(strcmp(text, "ENGRAIS") == 0);

	/* items: 44-byte entries with their own index at +14 */
	long itemAt = 0x40000;
	memset(rom + itemAt, 0, 44 * 60);
	memset(rom + itemAt, 0xAC, 8);
	rom[itemAt + 8] = 0xFF;
	for (int i = 1; i < 60; ++i) {
		put_text(rom + itemAt + i * 44, i == 4 ? "POKE BALL" : "OBJET");
		rom[itemAt + i * 44 + 14] = (uint8_t) i;
	}
	CHECK(pk_rom_find_items(rom, ROM) == itemAt);
	pk_rom_table_name(rom, ROM, itemAt, PK_ITEM_STRIDE, 4, text, sizeof(text));
	CHECK(strcmp(text, "POKE BALL") == 0);

	/* locations, Emerald style: 100 entries of {x, y, w, h, name pointer} */
	long namesAt = 0x50000, mapAt = 0x60000;
	size_t textAt = (size_t) namesAt;
	for (int i = 0; i < 100; ++i) {
		char name[24];
		snprintf(name, sizeof(name), i == 16 ? "ROUTE 101" : "LIEU %d", i);
		put_text(rom + textAt, name);
		uint8_t* e = rom + mapAt + i * 8;
		e[0] = (uint8_t) (i % 28);
		e[1] = (uint8_t) (i % 15);
		e[2] = 1;
		e[3] = 1;
		uint32_t ptr = 0x08000000u + (uint32_t) textAt;
		e[4] = (uint8_t) ptr;
		e[5] = (uint8_t) (ptr >> 8);
		e[6] = (uint8_t) (ptr >> 16);
		e[7] = (uint8_t) (ptr >> 24);
		textAt += strlen(name) + 1;
	}
	memset(rom + mapAt + 100 * 8, 0, 8);
	int kind = -1;
	unsigned count = 0;
	CHECK(pk_rom_find_location_names(rom, ROM, &kind, &count) == mapAt);
	CHECK(kind == PK_MAPSEC_REGION_MAP && count == 100);
	pk_rom_location_name(rom, ROM, mapAt, kind, count, 16, text, sizeof(text));
	CHECK(strcmp(text, "ROUTE 101") == 0);
	pk_rom_location_name(rom, ROM, mapAt, kind, count, 0xFD, text, sizeof(text));
	CHECK(text[0] == '\0');
	pk_rom_location_name(rom, ROM, mapAt, kind, count, 150, text, sizeof(text));
	CHECK(text[0] == '\0');

	/* FireRed style: break the region map, add a list of 109 pointers */
	memset(rom + mapAt, 0, 100 * 8);
	long listAt = 0x70000;
	for (int i = 0; i < 109; ++i) {
		uint32_t ptr = 0x08000000u + (uint32_t) namesAt;
		if (i == 1) {
			ptr = 0x08000000u + (uint32_t) namesAt + 7; /* "LIEU 1" -> second string */
		}
		rom[listAt + i * 4] = (uint8_t) ptr;
		rom[listAt + i * 4 + 1] = (uint8_t) (ptr >> 8);
		rom[listAt + i * 4 + 2] = (uint8_t) (ptr >> 16);
		rom[listAt + i * 4 + 3] = (uint8_t) (ptr >> 24);
	}
	memset(rom + listAt + 109 * 4, 0, 4);
	CHECK(pk_rom_find_location_names(rom, ROM, &kind, &count) == listAt);
	CHECK(kind == PK_MAPSEC_NAME_LIST && count == 109);
	pk_rom_location_name(rom, ROM, listAt, kind, count, 0x59, text, sizeof(text));
	CHECK(strcmp(text, "LIEU 1") == 0);
	pk_rom_location_name(rom, ROM, listAt, kind, count, 0x10, text, sizeof(text));
	CHECK(text[0] == '\0');

	free(rom);
}

int main(void) {
	test_text();
	test_mon();
	test_save();
	test_live();
	test_info();
	printf("%d checks, %d failures\n", checks, failures);
	return failures ? 1 : 0;
}
