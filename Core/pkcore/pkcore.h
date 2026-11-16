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

/* Locate the species / move name tables in a Western ROM. Return -1 if not found. */
long pk_rom_find_species_names(const uint8_t* rom, size_t size);
long pk_rom_find_move_names(const uint8_t* rom, size_t size);
/* Reads entry `index` of a name table found above. */
void pk_rom_table_name(const uint8_t* rom, size_t size, long table, size_t stride, unsigned index, char* out,
                       size_t outSize);

#ifdef __cplusplus
}
#endif

#endif
