/* pkcore: portable C helpers for Generation 3 Pokemon data.
 * Save files, Pokemon structures, text, live-memory lookups.
 * No dependency on the emulator; unit-tested on Linux (Core/tests).
 *
 * Licensed under the GNU GPL v3 (see LICENSE).
 */
#ifndef PKCORE_H
#define PKCORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PK_BOX_MON_SIZE 80
#define PK_PARTY_MON_SIZE 100
#define PK_BOX_COUNT 14
#define PK_BOX_SLOTS 30
#define PK_TEXT_UTF8 48

/* ---------- Text ---------- */

/* Decodes game text (Western charset) to UTF-8. Stops at the 0xFF terminator or
 * after maxLen bytes. Always NUL-terminates. Returns the UTF-8 length. */
size_t pk_text_decode(const uint8_t* in, size_t maxLen, char* out, size_t outSize);

/* ---------- Pokemon structure ---------- */

typedef struct {
	bool valid; /* checksum matches and a species is present */
	bool isEgg;
	bool isBadEgg;
	bool isShiny;
	bool hasPartyData;
	uint16_t species; /* the game's internal index, not the National Dex number */
	uint16_t heldItem;
	uint32_t experience;
	uint32_t personality;
	uint32_t otId;
	uint16_t moves[4];
	uint8_t pp[4];
	uint8_t evs[6]; /* HP, Atk, Def, Spe, SpA, SpD */
	uint8_t ivs[6]; /* same order */
	uint8_t friendship;
	uint8_t metLevel;
	uint8_t metLocation;
	uint8_t ball;
	uint8_t originGame;
	uint8_t language;
	uint8_t abilityBit;
	uint8_t otGender; /* 0 male, 1 female */
	uint8_t pokerus; /* strain in the high nibble, days left in the low nibble */
	uint8_t markings;
	uint8_t contest[6]; /* cool, beauty, cute, smart, tough, sheen */
	uint32_t ribbons; /* raw ribbon bits, see pk_ribbon_count */
	uint8_t nature; /* 0..24, personality % 25 */
	uint8_t hiddenPowerType; /* 0 Fighting .. 15 Dark */
	uint8_t hiddenPowerPower; /* 30..70 */
	/* Only when hasPartyData (100-byte structure): */
	uint32_t status;
	uint8_t level;
	uint16_t hp, maxHp, attack, defense, speed, spAttack, spDefense;
	char nickname[PK_TEXT_UTF8];
	char otName[PK_TEXT_UTF8];
} PKMon;

/* Decodes an 80-byte (boxed) or 100-byte (party) structure. Returns out->valid. */
bool pk_mon_decode(const uint8_t* raw, size_t rawSize, PKMon* out);

/* True when the 80-byte slot holds nothing. */
bool pk_mon_is_empty(const uint8_t* raw80);

/* Sets current HP to max HP and clears the status condition of a 100-byte party
 * structure, in place. Returns false (and changes nothing) if it does not decode. */
bool pk_party_heal(uint8_t* raw100);

/* ---------- Derived information ---------- */

/* One entry of the ROM's base stats table (28 bytes per species). */
typedef struct {
	uint8_t baseStats[6]; /* HP, Atk, Def, Spe, SpA, SpD */
	uint8_t type1, type2; /* 0 Normal .. 17 Dark (9 is unused) */
	uint8_t catchRate;
	uint8_t expYield;
	uint16_t item1, item2; /* wild held items */
	uint8_t genderRatio; /* 0 always male, 254 always female, 255 genderless */
	uint8_t eggCycles;
	uint8_t baseFriendship;
	uint8_t growthRate; /* 0 medium fast, 1 erratic, 2 fluctuating, 3 medium slow, 4 fast, 5 slow */
	uint8_t eggGroup1, eggGroup2;
	uint8_t ability1, ability2;
} PKBaseStats;

/* Experience needed to reach `level` (1..100). */
uint32_t pk_exp_for_level(uint8_t growthRate, unsigned level);
/* Level matching an experience total. */
uint8_t pk_level_for_exp(uint8_t growthRate, uint32_t exp);

/* Stats from base stats, IVs, EVs, level and nature, in the order HP, Atk, Def,
 * Spe, SpA, SpD. `species` is the internal index (Shedinja always has 1 HP). */
void pk_calc_stats(const PKBaseStats* base, const uint8_t ivs[6], const uint8_t evs[6], unsigned level,
                   unsigned nature, uint16_t species, uint16_t out[6]);

/* Stat raised and lowered by a nature, as an index into Atk, Def, Spe, SpA, SpD
 * (0..4). Both are -1 for neutral natures. */
void pk_nature_effect(unsigned nature, int* raised, int* lowered);

/* 0 male, 1 female, 2 genderless. */
int pk_gender(uint32_t personality, uint8_t genderRatio);

/* Number of ribbons, counting each contest rank as one. */
unsigned pk_ribbon_count(uint32_t ribbons);

/* ---------- Save files ---------- */

enum {
	PK_OK = 0,
	PK_ERR_SIZE = 1, /* not a 128 KB Gen 3 save */
	PK_ERR_NO_SLOT = 2, /* no valid save slot found */
	PK_ERR_CHECKSUM = 3, /* PC sections do not match the known layout */
	PK_ERR_MEMORY = 4,
	PK_ERR_RANGE = 5,
	PK_ERR_INVALID_MON = 6,
	PK_ERR_OCCUPIED = 7
};

enum { PK_GAME_UNKNOWN = 0, PK_GAME_RS = 1, PK_GAME_FRLG = 2, PK_GAME_EMERALD = 3 };

typedef struct PKSave PKSave;

/* Parses a copy of the save data. Returns NULL and sets *err on failure. */
PKSave* pk_save_open(const uint8_t* data, size_t size, int* err);
void pk_save_free(PKSave* save);

int pk_save_game(const PKSave* save);
void pk_save_trainer_name(const PKSave* save, char* out, size_t outSize);
uint32_t pk_save_trainer_id(const PKSave* save);
/* Hours in the high 16 bits, minutes in the low 16. */
uint32_t pk_save_play_time(const PKSave* save);

/* Pointer to the 80 bytes of a PC slot (inside the save object), or NULL. */
const uint8_t* pk_save_box_mon(const PKSave* save, int box, int slot);
void pk_save_box_name(const PKSave* save, int box, char* out, size_t outSize);

/* Writes a Pokemon into an empty PC slot. raw80 must decode cleanly. */
int pk_save_put_box_mon(PKSave* save, int box, int slot, const uint8_t* raw80);
/* Empties a PC slot. */
int pk_save_clear_box_mon(PKSave* save, int box, int slot);
/* Finds the first empty PC slot. Returns false when the PC is full. */
bool pk_save_first_empty(const PKSave* save, int* box, int* slot);

/* Size needed by pk_save_write. */
size_t pk_save_size(const PKSave* save);
/* Writes the full save (with PC changes and fresh checksums) to out. Returns
 * the number of bytes written, or 0 if outSize is too small. */
size_t pk_save_write(const PKSave* save, uint8_t* out, size_t outSize);

/* ---------- Live memory ---------- */

typedef struct {
	char code[5]; /* 4-letter game code from the ROM header */
	uint8_t revision;
	uint32_t playerParty;
	uint32_t playerPartyCount;
	uint32_t enemyParty; /* 0 when unknown */
	uint32_t gMain;
	uint32_t saveBlock1Ptr;
	uint32_t saveBlock2Ptr;
	uint32_t pokemonStoragePtr; /* 0 when unknown */
	uint8_t staticSaveBlocks;
} PKProfile;

extern const PKProfile pk_profiles[];
extern const size_t pk_profile_count;

/* Looks up addresses for a retail game. Falls back to the same code with another
 * revision when the exact one is not listed. NULL when the game is unknown. */
const PKProfile* pk_profile_find(const char* code4, uint8_t revision);

/* Fallback for unknown games (hacks): scans a RAM dump for a run of valid
 * 100-byte party structures. Returns the offset of the first one, or -1. */
long pk_scan_party(const uint8_t* ram, size_t size, int* countOut);

/* ---------- ROM tables ---------- */

#define PK_SPECIES_NAME_STRIDE 11
#define PK_MOVE_NAME_STRIDE 13
#define PK_ABILITY_NAME_STRIDE 13
#define PK_ITEM_STRIDE 44
#define PK_ITEM_NAME_LENGTH 14

enum { PK_MAPSEC_NONE = 0, PK_MAPSEC_REGION_MAP = 1, PK_MAPSEC_NAME_LIST = 2 };

/* Locate the species / move name tables in a Western ROM. Return -1 if not found. */
long pk_rom_find_species_names(const uint8_t* rom, size_t size);
long pk_rom_find_move_names(const uint8_t* rom, size_t size);
long pk_rom_find_ability_names(const uint8_t* rom, size_t size);
long pk_rom_find_items(const uint8_t* rom, size_t size);
long pk_rom_find_base_stats(const uint8_t* rom, size_t size);
long pk_rom_find_national_dex(const uint8_t* rom, size_t size);
/* Where location names live. *kind is PK_MAPSEC_REGION_MAP (Ruby, Sapphire,
 * Emerald: 8-byte entries indexed by location) or PK_MAPSEC_NAME_LIST (FireRed,
 * LeafGreen: pointers, Kanto locations only). *count is the number of entries. */
long pk_rom_find_location_names(const uint8_t* rom, size_t size, int* kind, unsigned* count);

bool pk_rom_base_stats(const uint8_t* rom, size_t size, long table, uint16_t species, PKBaseStats* out);
/* National Pokedex number of an internal species index, 0 when unknown. */
unsigned pk_rom_national_dex(const uint8_t* rom, size_t size, long table, uint16_t species);
/* Name of a capture location (the met location byte). Empty when unknown. */
void pk_rom_location_name(const uint8_t* rom, size_t size, long table, int kind, unsigned count,
                          unsigned location, char* out, size_t outSize);

/* Reads entry `index` of a name table found above (species, moves, abilities,
 * and items with stride PK_ITEM_STRIDE). */
void pk_rom_table_name(const uint8_t* rom, size_t size, long table, size_t stride, unsigned index, char* out,
                       size_t outSize);

#ifdef __cplusplus
}
#endif

#endif
