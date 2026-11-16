/* Generation 3 Pokemon structure (80 bytes boxed, 100 bytes in the party). GPL v3. */
#include "pkcore.h"

#include <string.h>

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

static void wr32(uint8_t* p, uint32_t v) {
	p[0] = (uint8_t) v;
	p[1] = (uint8_t) (v >> 8);
	p[2] = (uint8_t) (v >> 16);
	p[3] = (uint8_t) (v >> 24);
}

/* Position of each substructure (Growth, Attacks, EVs, Misc) for personality % 24. */
static const uint8_t kOrder[24][4] = {
	/* G  A  E  M */
	{ 0, 1, 2, 3 }, { 0, 1, 3, 2 }, { 0, 2, 1, 3 }, { 0, 3, 1, 2 }, { 0, 2, 3, 1 }, { 0, 3, 2, 1 },
	{ 1, 0, 2, 3 }, { 1, 0, 3, 2 }, { 2, 0, 1, 3 }, { 3, 0, 1, 2 }, { 2, 0, 3, 1 }, { 3, 0, 2, 1 },
	{ 1, 2, 0, 3 }, { 1, 3, 0, 2 }, { 2, 1, 0, 3 }, { 3, 1, 0, 2 }, { 2, 3, 0, 1 }, { 3, 2, 0, 1 },
	{ 1, 2, 3, 0 }, { 1, 3, 2, 0 }, { 2, 1, 3, 0 }, { 3, 1, 2, 0 }, { 2, 3, 1, 0 }, { 3, 2, 1, 0 },
};

static void decrypt_block(const uint8_t* raw, uint8_t out[48]) {
	uint32_t key = rd32(raw) ^ rd32(raw + 4);
	for (int i = 0; i < 48; i += 4) {
		wr32(out + i, rd32(raw + 32 + i) ^ key);
	}
}

static uint16_t block_checksum(const uint8_t data[48]) {
	uint16_t sum = 0;
	for (int i = 0; i < 48; i += 2) {
		sum = (uint16_t) (sum + rd16(data + i));
	}
	return sum;
}

bool pk_mon_is_empty(const uint8_t* raw80) {
	if (!raw80) {
		return true;
	}
	/* hasSpecies flag clear, or nothing at all in the slot */
	if (!(raw80[19] & 0x02)) {
		return true;
	}
	for (int i = 0; i < PK_BOX_MON_SIZE; ++i) {
		if (raw80[i]) {
			return false;
		}
	}
	return true;
}

bool pk_mon_decode(const uint8_t* raw, size_t rawSize, PKMon* out) {
	if (!out) {
		return false;
	}
	memset(out, 0, sizeof(*out));
	if (!raw || rawSize < PK_BOX_MON_SIZE) {
		return false;
	}

	uint8_t data[48];
	decrypt_block(raw, data);

	out->personality = rd32(raw);
	out->otId = rd32(raw + 4);
	out->language = raw[18];
	out->isBadEgg = (raw[19] & 0x01) != 0;
	bool hasSpecies = (raw[19] & 0x02) != 0;
	out->isEgg = (raw[19] & 0x04) != 0;
	pk_text_decode(raw + 8, 10, out->nickname, sizeof(out->nickname));
	pk_text_decode(raw + 20, 7, out->otName, sizeof(out->otName));

	const uint8_t* order = kOrder[out->personality % 24];
	const uint8_t* growth = data + order[0] * 12;
	const uint8_t* attacks = data + order[1] * 12;
	const uint8_t* evs = data + order[2] * 12;
	const uint8_t* misc = data + order[3] * 12;

	out->species = rd16(growth);
	out->heldItem = rd16(growth + 2);
	out->experience = rd32(growth + 4);
	out->friendship = growth[9];
	for (int i = 0; i < 4; ++i) {
		out->moves[i] = rd16(attacks + i * 2);
		out->pp[i] = attacks[8 + i];
	}
	for (int i = 0; i < 6; ++i) {
		out->evs[i] = evs[i];
	}
	out->metLocation = misc[1];
	uint16_t origins = rd16(misc + 2);
	out->metLevel = origins & 0x7F;
	out->originGame = (origins >> 7) & 0x0F;
	out->ball = (origins >> 11) & 0x0F;
	uint32_t ivWord = rd32(misc + 4);
	for (int i = 0; i < 6; ++i) {
		out->ivs[i] = (ivWord >> (5 * i)) & 0x1F;
	}
	if (ivWord & 0x40000000u) {
		out->isEgg = true;
	}
	out->abilityBit = (uint8_t) (ivWord >> 31);
	out->otGender = (uint8_t) (origins >> 15);
	out->pokerus = misc[0];
	out->ribbons = rd32(misc + 8);
	out->markings = raw[27];
	for (int i = 0; i < 6; ++i) {
		out->contest[i] = evs[6 + i];
	}
	out->nature = (uint8_t) (out->personality % 25);
	unsigned typeBits = 0, powerBits = 0;
	for (int i = 0; i < 6; ++i) {
		typeBits |= (unsigned) (out->ivs[i] & 1) << i;
		powerBits |= (unsigned) ((out->ivs[i] >> 1) & 1) << i;
	}
	out->hiddenPowerType = (uint8_t) (typeBits * 15 / 63);
	out->hiddenPowerPower = (uint8_t) (powerBits * 40 / 63 + 30);

	uint32_t p = out->personality;
	uint32_t shinyValue = (out->otId >> 16) ^ (out->otId & 0xFFFF) ^ (p >> 16) ^ (p & 0xFFFF);
	out->isShiny = shinyValue < 8;

	if (rawSize >= PK_PARTY_MON_SIZE) {
		out->hasPartyData = true;
		out->status = rd32(raw + 80);
		out->level = raw[84];
		out->hp = rd16(raw + 86);
		out->maxHp = rd16(raw + 88);
		out->attack = rd16(raw + 90);
		out->defense = rd16(raw + 92);
		out->speed = rd16(raw + 94);
		out->spAttack = rd16(raw + 96);
		out->spDefense = rd16(raw + 98);
	}

	out->valid = hasSpecies && !out->isBadEgg && out->species != 0 && block_checksum(data) == rd16(raw + 28);
	return out->valid;
}

bool pk_party_heal(uint8_t* raw100) {
	PKMon mon;
	if (!pk_mon_decode(raw100, PK_PARTY_MON_SIZE, &mon) || mon.maxHp == 0) {
		return false;
	}
	wr32(raw100 + 80, 0);
	wr16(raw100 + 86, mon.maxHp);
	return true;
}
