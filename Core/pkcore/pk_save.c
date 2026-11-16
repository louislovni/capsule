/* Generation 3 save files (Ruby/Sapphire/Emerald/FireRed/LeafGreen). GPL v3.
 *
 * Layout: two save slots of 14 sections, 0x1000 bytes each. Every section ends
 * with a footer: section id (0xFF4), checksum (0xFF6), signature (0xFF8) and
 * save counter (0xFFC). Sections 5..13 hold the PC storage, which is the only
 * part this code ever modifies.
 */
#include "pkcore.h"

#include <stdlib.h>
#include <string.h>

#define SECTION_SIZE 0x1000
#define SECTIONS_PER_SLOT 14
#define SLOT_SIZE (SECTION_SIZE * SECTIONS_PER_SLOT)
#define MIN_SAVE_SIZE (SLOT_SIZE * 2)
#define SIGNATURE 0x08012025u
#define FOOTER_ID 0xFF4
#define FOOTER_CHECKSUM 0xFF6
#define FOOTER_SIGNATURE 0xFF8
#define FOOTER_COUNTER 0xFFC

#define PC_FIRST_SECTION 5
#define PC_SECTION_COUNT 9
#define PC_CHUNK 3968
#define PC_LAST_CHUNK 2000
#define PC_SIZE (PC_CHUNK * 8 + PC_LAST_CHUNK) /* 33744 */
#define PC_MONS_OFFSET 4
#define PC_NAMES_OFFSET (PC_MONS_OFFSET + PK_BOX_COUNT * PK_BOX_SLOTS * PK_BOX_MON_SIZE)

struct PKSave {
	uint8_t* data;
	size_t size;
	int slot; /* active slot: 0 or 1 */
	int sectionIndex[SECTIONS_PER_SLOT]; /* section id -> physical index inside the slot */
	uint8_t pc[PC_SIZE];
	bool pcDirty;
};

static uint16_t rd16(const uint8_t* p) {
	return (uint16_t) (p[0] | (p[1] << 8));
}

static uint32_t rd32(const uint8_t* p) {
	return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

static void wr16(uint8_t* p, uint16_t v) {
	p[0] = (uint8_t) v;
	p[1] = (uint8_t) (v >> 8);
}

static uint16_t section_checksum(const uint8_t* data, size_t size) {
	uint32_t sum = 0;
	for (size_t i = 0; i + 4 <= size; i += 4) {
		sum += rd32(data + i);
	}
	return (uint16_t) ((sum >> 16) + (sum & 0xFFFF));
}

static size_t pc_chunk_size(int pcIndex) {
	return pcIndex == PC_SECTION_COUNT - 1 ? PC_LAST_CHUNK : PC_CHUNK;
}

/* Checks one slot; fills index[] and the save counter. */
static bool read_slot(const uint8_t* data, int slot, int index[SECTIONS_PER_SLOT], uint32_t* counter) {
	bool seen[SECTIONS_PER_SLOT] = { false };
	const uint8_t* base = data + (size_t) slot * SLOT_SIZE;
	for (int i = 0; i < SECTIONS_PER_SLOT; ++i) {
		const uint8_t* section = base + (size_t) i * SECTION_SIZE;
		if (rd32(section + FOOTER_SIGNATURE) != SIGNATURE) {
			return false;
		}
		uint16_t id = rd16(section + FOOTER_ID);
		if (id >= SECTIONS_PER_SLOT || seen[id]) {
			return false;
		}
		seen[id] = true;
		index[id] = i;
		if (id == 0) {
			*counter = rd32(section + FOOTER_COUNTER);
		}
	}
	return true;
}

static const uint8_t* section_ptr(const PKSave* save, int id) {
	return save->data + (size_t) save->slot * SLOT_SIZE + (size_t) save->sectionIndex[id] * SECTION_SIZE;
}

PKSave* pk_save_open(const uint8_t* data, size_t size, int* err) {
	int dummy;
	if (!err) {
		err = &dummy;
	}
	*err = PK_OK;
	if (!data || size < MIN_SAVE_SIZE) {
		*err = PK_ERR_SIZE;
		return NULL;
	}

	int index[2][SECTIONS_PER_SLOT];
	uint32_t counter[2] = { 0, 0 };
	bool ok[2];
	ok[0] = read_slot(data, 0, index[0], &counter[0]);
	ok[1] = read_slot(data, 1, index[1], &counter[1]);
	if (!ok[0] && !ok[1]) {
		*err = PK_ERR_NO_SLOT;
		return NULL;
	}
	int slot;
	if (ok[0] && ok[1]) {
		slot = counter[1] > counter[0] ? 1 : 0;
	} else {
		slot = ok[0] ? 0 : 1;
	}

	PKSave* save = calloc(1, sizeof(*save));
	if (!save) {
		*err = PK_ERR_MEMORY;
		return NULL;
	}
	save->data = malloc(size);
	if (!save->data) {
		free(save);
		*err = PK_ERR_MEMORY;
		return NULL;
	}
	memcpy(save->data, data, size);
	save->size = size;
	save->slot = slot;
	memcpy(save->sectionIndex, index[slot], sizeof(save->sectionIndex));

	/* Rebuild the PC buffer and make sure the layout is the one we know:
	 * if the checksums do not match, we refuse to work on this file. */
	size_t offset = 0;
	for (int i = 0; i < PC_SECTION_COUNT; ++i) {
		const uint8_t* section = section_ptr(save, PC_FIRST_SECTION + i);
		size_t chunk = pc_chunk_size(i);
		if (section_checksum(section, chunk) != rd16(section + FOOTER_CHECKSUM)) {
			pk_save_free(save);
			*err = PK_ERR_CHECKSUM;
			return NULL;
		}
		memcpy(save->pc + offset, section, chunk);
		offset += chunk;
	}
	return save;
}

void pk_save_free(PKSave* save) {
	if (!save) {
		return;
	}
	free(save->data);
	free(save);
}

int pk_save_game(const PKSave* save) {
	if (!save) {
		return PK_GAME_UNKNOWN;
	}
	uint32_t code = rd32(section_ptr(save, 0) + 0xAC);
	if (code == 0) {
		return PK_GAME_RS;
	}
	if (code == 1) {
		return PK_GAME_FRLG;
	}
	return PK_GAME_EMERALD;
}

void pk_save_trainer_name(const PKSave* save, char* out, size_t outSize) {
	if (!save) {
		if (out && outSize) {
			out[0] = '\0';
		}
		return;
	}
	pk_text_decode(section_ptr(save, 0), 7, out, outSize);
}

uint32_t pk_save_trainer_id(const PKSave* save) {
	return save ? rd32(section_ptr(save, 0) + 0x0A) : 0;
}

uint32_t pk_save_play_time(const PKSave* save) {
	if (!save) {
		return 0;
	}
	const uint8_t* s = section_ptr(save, 0);
	return ((uint32_t) rd16(s + 0x0E) << 16) | s[0x10];
}

static bool slot_in_range(int box, int slot) {
	return box >= 0 && box < PK_BOX_COUNT && slot >= 0 && slot < PK_BOX_SLOTS;
}

static size_t mon_offset(int box, int slot) {
	return PC_MONS_OFFSET + ((size_t) box * PK_BOX_SLOTS + (size_t) slot) * PK_BOX_MON_SIZE;
}

const uint8_t* pk_save_box_mon(const PKSave* save, int box, int slot) {
	if (!save || !slot_in_range(box, slot)) {
		return NULL;
	}
	return save->pc + mon_offset(box, slot);
}

void pk_save_box_name(const PKSave* save, int box, char* out, size_t outSize) {
	if (!save || box < 0 || box >= PK_BOX_COUNT) {
		if (out && outSize) {
			out[0] = '\0';
		}
		return;
	}
	pk_text_decode(save->pc + PC_NAMES_OFFSET + (size_t) box * 9, 9, out, outSize);
}

int pk_save_put_box_mon(PKSave* save, int box, int slot, const uint8_t* raw80) {
	if (!save || !slot_in_range(box, slot)) {
		return PK_ERR_RANGE;
	}
	PKMon mon;
	if (!raw80 || !pk_mon_decode(raw80, PK_BOX_MON_SIZE, &mon)) {
		return PK_ERR_INVALID_MON;
	}
	uint8_t* dest = save->pc + mon_offset(box, slot);
	if (!pk_mon_is_empty(dest)) {
		return PK_ERR_OCCUPIED;
	}
	memcpy(dest, raw80, PK_BOX_MON_SIZE);
	save->pcDirty = true;
	return PK_OK;
}

int pk_save_clear_box_mon(PKSave* save, int box, int slot) {
	if (!save || !slot_in_range(box, slot)) {
		return PK_ERR_RANGE;
	}
	memset(save->pc + mon_offset(box, slot), 0, PK_BOX_MON_SIZE);
	save->pcDirty = true;
	return PK_OK;
}

bool pk_save_first_empty(const PKSave* save, int* box, int* slot) {
	if (!save) {
		return false;
	}
	for (int b = 0; b < PK_BOX_COUNT; ++b) {
		for (int s = 0; s < PK_BOX_SLOTS; ++s) {
			if (pk_mon_is_empty(save->pc + mon_offset(b, s))) {
				if (box) {
					*box = b;
				}
				if (slot) {
					*slot = s;
				}
				return true;
			}
		}
	}
	return false;
}

size_t pk_save_size(const PKSave* save) {
	return save ? save->size : 0;
}

size_t pk_save_write(const PKSave* save, uint8_t* out, size_t outSize) {
	if (!save || !out || outSize < save->size) {
		return 0;
	}
	memcpy(out, save->data, save->size);
	if (save->pcDirty) {
		size_t offset = 0;
		for (int i = 0; i < PC_SECTION_COUNT; ++i) {
			size_t physical = (size_t) save->slot * SLOT_SIZE +
			                  (size_t) save->sectionIndex[PC_FIRST_SECTION + i] * SECTION_SIZE;
			uint8_t* section = out + physical;
			size_t chunk = pc_chunk_size(i);
			memcpy(section, save->pc + offset, chunk);
			wr16(section + FOOTER_CHECKSUM, section_checksum(section, chunk));
			offset += chunk;
		}
	}
	return save->size;
}
