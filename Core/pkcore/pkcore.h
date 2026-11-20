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

/* Changes the species and held item of a valid structure (checksum and encryption kept right).
 * The nickname bytes (raw + 8, 10 bytes) are not touched. */
bool pk_mon_set_species(uint8_t* raw, size_t rawSize, uint16_t species, uint16_t heldItem);

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

/* Pokedex flags of a save: bit (dex - 1) of caught[] / seen[] (seen includes caught). */
#define PK_DEX_FLAG_BYTES 82 /* 649 species and some room */

/* The team: up to 6 copies of 100-byte structures in out (600 bytes). Returns how many. */
int pk_save_party(const PKSave* save, uint8_t* out);
bool pk_save_pokedex(const PKSave* save, uint8_t caught[PK_DEX_FLAG_BYTES], uint8_t seen[PK_DEX_FLAG_BYTES]);

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

/* ---------- Game Boy games: generations 1 and 2 ---------- */

enum { PK_GB_GEN1 = 1, PK_GB_GS = 2, PK_GB_CRYSTAL = 3 };

#define PK_GB_NAME_LENGTH 11
#define PK_GB1_BOX_MON 33
#define PK_GB1_PARTY_MON 44
#define PK_GB2_BOX_MON 32
#define PK_GB2_PARTY_MON 48
#define PK_GB_BOX_SLOTS 20
/* What the bank keeps for a Game Boy Pokemon: the box structure, then the
 * trainer name and the nickname (stored apart in these games), then the byte
 * of the species list (0xFD for a generation 2 egg). */
#define PK_GB1_BLOB 56 /* 33 + 11 + 11 + 1; a plain number so that Swift can import it */
#define PK_GB2_BLOB 55 /* 32 + 11 + 11 + 1 */

/* Text of the Western Game Boy games to UTF-8. Stops at 0x50. */
size_t pk_gb_text_decode(const uint8_t* in, size_t maxLen, char* out, size_t outSize);

typedef struct {
	bool valid;
	uint8_t generation; /* 1 or 2 */
	bool isEgg;
	bool isShiny; /* generation 2 only */
	uint8_t species; /* internal index: Red/Blue/Yellow order, Pokedex order in Gold/Silver/Crystal */
	uint16_t dex; /* National Pokedex number */
	uint8_t level;
	uint8_t heldItem; /* generation 2; catch rate byte in generation 1 */
	uint8_t moves[4];
	uint8_t pp[4];
	uint8_t ppUps[4];
	uint16_t otId;
	uint32_t experience;
	uint16_t statExp[5]; /* HP, Atk, Def, Spe, Special */
	uint8_t dvs[5]; /* same order; the HP DV is derived from the others */
	uint8_t friendship; /* generation 2 */
	uint8_t pokerus; /* generation 2 */
	bool hasCaughtData; /* Crystal only */
	uint8_t metTime; /* 1 morning, 2 day, 3 night */
	uint8_t metLevel;
	uint8_t metLocation;
	uint8_t otGender;
	uint8_t status;
	uint16_t hp;
	bool hasPartyData;
	uint16_t stats[6]; /* party only: max HP, Atk, Def, Spe, SpA, SpD (SpA = SpD in generation 1) */
	char nickname[PK_TEXT_UTF8];
	char otName[PK_TEXT_UTF8];
} PKGBMon;

/* Decodes a box (33 / 32 bytes) or party (44 / 48 bytes) structure with its
 * names. listSpecies is the byte of the species list (pass mon[0] if unknown). */
bool pk_gb_mon_decode(int generation, const uint8_t* mon, size_t monSize, const uint8_t* otName,
                      const uint8_t* nickname, uint8_t listSpecies, PKGBMon* out);
/* Decodes a bank blob (PK_GB1_BLOB / PK_GB2_BLOB bytes). */
bool pk_gb_blob_decode(int generation, const uint8_t* blob, size_t size, PKGBMon* out);

/* Changes the species (National Pokedex number) of a bank blob. heldItem < 0 keeps it
 * (generation 2 only). nickname, when not NULL, is written in the game's charset
 * (letters, digits, space, '-' and '.'); false when it can't be. */
bool pk_gb_blob_set_species(int generation, uint8_t* blob, size_t size, unsigned dex, int heldItem,
                            const char* nickname);

/* Base stats from the built-in tables, by National Pokedex number.
 * Order: HP, Atk, Def, Spe, SpA, SpD (generation 1: Special twice). */
bool pk_gb_base_stats(int generation, unsigned dex, uint8_t stats[6], uint8_t* type1, uint8_t* type2,
                      uint8_t* genderRatio, uint8_t* growthRate);
/* Stats of a level: max HP, Atk, Def, Spe, SpA, SpD. */
void pk_gb_calc_stats(int generation, unsigned dex, const uint8_t dvs[5], const uint16_t statExp[5], unsigned level,
                      uint16_t out[6]);
/* 0 male, 1 female, 2 genderless (generation 2 rules). */
int pk_gb_gender(unsigned dex, const uint8_t dvs[5]);
/* Hidden Power of generation 2: type index as in PKMon (0 Fighting .. 15 Dark), power 31..70. */
void pk_gb_hidden_power(const uint8_t dvs[5], uint8_t* type, uint8_t* power);

/* Built-in French names (NULL when missing). Index 0 is never used. */
extern const char* const pk_gb_species_names[252]; /* by Pokedex number */
extern const char* const pk_gb_move_names[252];
extern const char* const pk_gb_item_names[256];
extern const char* const pk_gb_landmark_names[];
extern const size_t pk_gb_landmark_count;
extern const uint8_t pk_gb1_index_to_dex[256];
extern const uint8_t pk_gb1_base[152][8];
extern const uint8_t pk_gb2_base[252][10];

/* The same names, range-checked (NULL when unknown). */
const char* pk_gb_species_name(unsigned dex);
const char* pk_gb_move_name(unsigned move);
const char* pk_gb_item_name(unsigned item);
const char* pk_gb_landmark_name(unsigned landmark);

/* Finds the team in a dump of work RAM (0xC000-0xDFFF): returns the offset of
 * the count byte, or -1. Layout: count, species list, structures, trainer
 * names, nicknames. */
long pk_gb_scan_party(const uint8_t* ram, size_t size, int generation, int* countOut);

typedef struct PKGBSave PKGBSave;

PKGBSave* pk_gb_save_open(const uint8_t* data, size_t size, int* err);
void pk_gb_save_free(PKGBSave* save);
int pk_gb_save_game(const PKGBSave* save); /* PK_GB_GEN1, PK_GB_GS, PK_GB_CRYSTAL */
int pk_gb_save_generation(const PKGBSave* save);
void pk_gb_save_trainer_name(const PKGBSave* save, char* out, size_t outSize);
uint16_t pk_gb_save_trainer_id(const PKGBSave* save);
unsigned pk_gb_box_count(const PKGBSave* save);
int pk_gb_current_box(const PKGBSave* save);
/* False for boxes the game has not set up yet (Red/Blue/Yellow before the
 * first box change): they read as empty and cannot receive Pokemon. */
bool pk_gb_box_usable(const PKGBSave* save, int box);
unsigned pk_gb_box_size(const PKGBSave* save, int box);
void pk_gb_box_name(const PKGBSave* save, int box, char* out, size_t outSize);
size_t pk_gb_blob_size(const PKGBSave* save);
/* Copies the blob of one Pokemon; false when out of range. */
bool pk_gb_box_mon(const PKGBSave* save, int box, int index, uint8_t* blob);
int pk_gb_box_remove(PKGBSave* save, int box, int index);
int pk_gb_box_append(PKGBSave* save, int box, const uint8_t* blob, size_t size);
/* First box with room: the current one if possible. */
bool pk_gb_first_free(const PKGBSave* save, int* box);
size_t pk_gb_save_size(const PKGBSave* save);
/* The team as bank blobs (6 * pk_gb_blob_size bytes in out). Returns how many. */
int pk_gb_party(const PKGBSave* save, uint8_t* out);
bool pk_gb_pokedex(const PKGBSave* save, uint8_t caught[PK_DEX_FLAG_BYTES], uint8_t seen[PK_DEX_FLAG_BYTES]);
size_t pk_gb_save_write(const PKGBSave* save, uint8_t* out, size_t outSize);

/* ---------- DS games: generations 4 and 5 ---------- */

enum { PK_NDS_DP = 1, PK_NDS_PT = 2, PK_NDS_HGSS = 3, PK_NDS_BW = 4, PK_NDS_B2W2 = 5 };

/* A boxed Pokemon of the DS games, as stored in the save (encrypted). The bank
 * keeps exactly these bytes. */
#define PK_NDS_MON_SIZE 136
#define PK_NDS_SAVE_SIZE 0x80000

typedef struct {
	bool valid; /* checksum matches and a species is present */
	uint8_t generation; /* 4 or 5 */
	bool isEgg;
	bool isShiny;
	bool isNicknamed;
	bool fatefulEncounter;
	bool hiddenAbility; /* generation 5 */
	uint16_t species; /* National Pokedex number (0: an hg-engine hack's form or egg) */
	uint16_t storedSpecies; /* the game's own id: an hg-engine hack's go past 493 (pk_nds_national) */
	uint8_t form;
	uint8_t gender; /* 0 male, 1 female, 2 genderless */
	uint16_t heldItem;
	uint16_t tid, sid;
	uint32_t experience;
	uint32_t personality;
	uint8_t friendship;
	uint8_t ability;
	uint8_t markings;
	uint8_t language;
	uint8_t evs[6]; /* HP, Atk, Def, Spe, SpA, SpD */
	uint8_t ivs[6];
	uint8_t contest[6];
	uint16_t moves[4];
	uint8_t pp[4];
	uint8_t ppUps[4];
	uint8_t nature;
	uint8_t originGame;
	uint16_t metLocation, eggLocation;
	uint8_t metYear, metMonth, metDay; /* year since 2000 */
	uint8_t eggYear, eggMonth, eggDay;
	uint8_t pokerus;
	uint8_t ball; /* 1 Master .. 16 Cherish, 17..24 Apricorn balls, 25 Dream */
	uint8_t metLevel;
	uint8_t otGender;
	uint8_t encounterType;
	uint8_t hiddenPowerType; /* 0 Fighting .. 15 Dark */
	uint8_t hiddenPowerPower;
	unsigned ribbonCount;
	char nickname[PK_TEXT_UTF8];
	char otName[PK_TEXT_UTF8];
} PKNDSMon;

/* Decodes a 136-byte stored structure. generation is 4 or 5. */
bool pk_nds_mon_decode(int generation, const uint8_t* raw, size_t size, PKNDSMon* out);
/* True when the slot holds no Pokemon (any encryption of an empty structure). */
bool pk_nds_mon_is_empty(const uint8_t* raw136);
/* Encrypts / decrypts a 136-byte structure in place (shuffled order kept as stored). */
void pk_nds_crypt(uint8_t* raw136);
/* Changes species, held item, ability (< 0 keeps it) and, when not NULL, the nickname
 * (UTF-8) of a valid 136-byte structure; checksum and encryption are kept right. */
bool pk_nds_set_species(int generation, uint8_t* raw136, uint16_t species, uint16_t heldItem, int ability,
                        const char* nickname);
/* Builds the stored form of an empty slot (what the games write). */
void pk_nds_empty_slot(uint8_t* raw136);

typedef struct {
	uint8_t stats[6]; /* HP, Atk, Def, Spe, SpA, SpD */
	uint8_t type1, type2; /* 0 Normal .. 16 Dark */
	uint8_t genderRatio; /* 0 always male, 254 always female, 255 genderless */
	uint8_t growthRate; /* as PKBaseStats */
} PKNDSBase;

extern const PKNDSBase pk_nds_base[650]; /* by Pokedex number, generation 5 values */
extern const char* const pk_nds_species_names[650];
extern const char* const pk_nds_move_names[560];
extern const char* const pk_nds_ability_names[165];
extern const char* const pk_nds_item_names[639];
extern const char* const pk_nds_type_names[17];
extern const uint16_t pk_nds_charset[];
extern const size_t pk_nds_charset_count;
/* Name of a met or egg location, NULL when unknown. */
const char* pk_nds_location_name(int generation, unsigned location);
/* Range-checked lookups, NULL when unknown. */
const char* pk_nds_species_name(unsigned dex);
const char* pk_nds_move_name(unsigned move);
const char* pk_nds_ability_name(unsigned ability);
const char* pk_nds_item_name(unsigned item);
const char* pk_nds_type_name(unsigned type);
bool pk_nds_base_stats(unsigned dex, PKNDSBase* out);
/* Name of a ball by its PKNDSMon.ball value. */
const char* pk_nds_ball_name(unsigned ball);
/* Level of an experience total, with the species' growth rate. */
uint8_t pk_nds_level(unsigned dex, uint32_t exp);
/* Stats at a level: HP, Atk, Def, Spe, SpA, SpD. False when the species is unknown. */
bool pk_nds_calc_stats(unsigned dex, const uint8_t ivs[6], const uint8_t evs[6], unsigned level, unsigned nature,
                       uint16_t out[6]);

typedef struct PKNDSSave PKNDSSave;

/* Opens a 512 KB DS save of Diamond/Pearl/Platinum, HeartGold/SoulSilver,
 * Black/White or Black 2/White 2. Refuses (NULL, *err set) anything whose
 * layout or checksums do not match: the bank never writes to a save it does
 * not fully recognise. */
PKNDSSave* pk_nds_save_open(const uint8_t* data, size_t size, int* err);
void pk_nds_save_free(PKNDSSave* save);
int pk_nds_save_game(const PKNDSSave* save); /* PK_NDS_* */
int pk_nds_save_generation(const PKNDSSave* save); /* 4 or 5 */
/* An hg-engine HeartGold hack's save (Chaos Purple, Heartfelt Gold): 30 boxes, species ids past 493. */
bool pk_nds_save_hg_engine(const PKNDSSave* save);
/* A generation 4 species id's National Pokedex number: an hg-engine hack's Dex numbers to ARCEUS, then its egg and
 * 48 forms, VICTINI at 544 (50 past its number); 0 for a form or an egg. */
unsigned pk_nds_national(unsigned storedSpecies);
void pk_nds_save_trainer_name(const PKNDSSave* save, char* out, size_t outSize);
uint16_t pk_nds_save_trainer_id(const PKNDSSave* save);
/* Boxes the player can use (Black/White unlock theirs as they fill up). */
unsigned pk_nds_box_count(const PKNDSSave* save);
int pk_nds_current_box(const PKNDSSave* save);
void pk_nds_box_name(const PKNDSSave* save, int box, char* out, size_t outSize);
/* Copies the stored 136 bytes; false when the slot is empty or out of range. */
bool pk_nds_box_mon(const PKNDSSave* save, int box, int slot, uint8_t* raw136);
/* Writes a Pokemon into an empty slot. raw must decode cleanly. */
int pk_nds_put_box_mon(PKNDSSave* save, int box, int slot, const uint8_t* raw136);
int pk_nds_clear_box_mon(PKNDSSave* save, int box, int slot);
/* First empty slot, starting with the box selected in the game. */
bool pk_nds_first_empty(const PKNDSSave* save, int* box, int* slot);
size_t pk_nds_save_size(const PKNDSSave* save);
/* The team: up to 6 stored 136-byte structures in out (816 bytes). Returns how many. */
int pk_nds_party(const PKNDSSave* save, uint8_t* out);
bool pk_nds_pokedex(const PKNDSSave* save, uint8_t caught[PK_DEX_FLAG_BYTES], uint8_t seen[PK_DEX_FLAG_BYTES]);
/* Writes the save with fresh checksums. Returns the bytes written, 0 if out is too small. */
size_t pk_nds_save_write(const PKNDSSave* save, uint8_t* out, size_t outSize);

#ifdef __cplusplus
}
#endif


/* ---- ROM patches (pk_patch.c): IPS, UPS, BPS, xdelta ---- */
enum { PK_PATCH_UNKNOWN = 0, PK_PATCH_IPS, PK_PATCH_UPS, PK_PATCH_BPS, PK_PATCH_XDELTA };
enum {
	PK_PATCH_OK = 0,
	PK_PATCH_ERR_FORMAT = -1,       /* not a patch this knows */
	PK_PATCH_ERR_CORRUPT = -2,      /* the patch is damaged */
	PK_PATCH_ERR_WRONG_SOURCE = -3, /* the patch is for another ROM (UPS / BPS's CRC32, xdelta's sizes) */
	PK_PATCH_ERR_RESULT = -4,       /* the result's checksum doesn't match: usually the wrong ROM */
	PK_PATCH_ERR_UNSUPPORTED = -5,  /* a patch feature this can't read */
	PK_PATCH_ERR_MEMORY = -6,
};
int pk_patch_format(const uint8_t* patch, size_t size);
/* The patched ROM in *out (pk_patch_free it); PK_PATCH_OK or an error above. */
int pk_patch_apply(const uint8_t* source, size_t sourceSize, const uint8_t* patch, size_t patchSize,
                   uint8_t** out, size_t* outSize);
void pk_patch_free(uint8_t* data);
/* The CRC32 of the ROM a UPS or BPS patch is made for (1), or 0 when the patch doesn't say. */
int pk_patch_source_crc(const uint8_t* patch, size_t size, uint32_t* crc);
/* The size of the ROM a UPS or BPS patch is made for (1), or 0. */
int pk_patch_source_size(const uint8_t* patch, size_t size, uint64_t* sourceSize);
uint32_t pk_crc32(const uint8_t* data, size_t size);

#endif
