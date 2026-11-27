/* PokeDaisy's co-op messages (coop_wire.h). Licensed under the GNU GPL v3. */
#include "coop_wire.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char HEX[] = "0123456789abcdef";

bool coop_save_equal(const coop_save_id* a, const coop_save_id* b) {
	return a->trainerId == b->trainerId && a->secretId == b->secretId && !memcmp(a->name, b->name, 8);
}

void coop_save_key(const coop_save_id* s, char out[27]) {
	snprintf(out, 10, "%04x%04x-", s->trainerId, s->secretId);
	for (int i = 0; i < 8; i++) {
		out[9 + 2 * i] = HEX[s->name[i] >> 4];
		out[10 + 2 * i] = HEX[s->name[i] & 15];
	}
	out[25] = 0;
}

static bool version_ok(const char* v, size_t n) {
	if (n < 1 || n > 32) {
		return false;
	}
	for (size_t i = 0; i < n; i++) {
		char c = v[i];
		if (!(isalnum((unsigned char) c) || c == '.' || c == '+' || c == '-')) {
			return false;
		}
	}
	return true;
}

static bool ticket_text_ok(const char* t, size_t n) {
	if (n < 4 + 56 || n > 4 + 205 || strncmp(t, "pdco", 4)) {
		return false;
	}
	for (size_t i = 4; i < n; i++) {
		char c = t[i];
		if (!((c >= 'a' && c <= 'z') || (c >= '2' && c <= '7'))) {
			return false;
		}
	}
	return true;
}

size_t coop_hello_encode(const coop_hello* h, uint8_t* out) {
	size_t at = 0, vl = strlen(h->appVersion), tl = strlen(h->ticket);
	out[at++] = (uint8_t) (h->protocol >> 8);
	out[at++] = (uint8_t) h->protocol;
	out[at++] = (uint8_t) vl;
	memcpy(out + at, h->appVersion, vl);
	at += vl;
	memcpy(out + at, h->romSha1, 20);
	at += 20;
	out[at++] = (uint8_t) (h->save.trainerId >> 8);
	out[at++] = (uint8_t) h->save.trainerId;
	out[at++] = (uint8_t) (h->save.secretId >> 8);
	out[at++] = (uint8_t) h->save.secretId;
	memcpy(out + at, h->save.name, 8);
	at += 8;
	out[at++] = h->female ? 1 : 0;
	out[at++] = (uint8_t) (tl >> 8);
	out[at++] = (uint8_t) tl;
	memcpy(out + at, h->ticket, tl);
	return at + tl;
}

bool coop_hello_decode(const uint8_t* b, size_t n, coop_hello* h) {
	memset(h, 0, sizeof *h);
	size_t p = 0;
	if (n < 3) {
		return false;
	}
	h->protocol = b[0] << 8 | b[1];
	size_t vl = b[2];
	p = 3;
	if (vl < 1 || vl > 32 || n - p < vl + 20 + 2 + 2 + 8 + 1 + 2) {
		return false;
	}
	if (!version_ok((const char*) b + p, vl)) {
		return false;
	}
	memcpy(h->appVersion, b + p, vl);
	p += vl;
	memcpy(h->romSha1, b + p, 20);
	p += 20;
	h->save.trainerId = (uint16_t) (b[p] << 8 | b[p + 1]);
	h->save.secretId = (uint16_t) (b[p + 2] << 8 | b[p + 3]);
	p += 4;
	memcpy(h->save.name, b + p, 8);
	p += 8;
	if (b[p] > 1) {
		return false;
	}
	h->female = b[p++] == 1;
	size_t tl = (size_t) (b[p] << 8 | b[p + 1]);
	p += 2;
	if (tl > 2048 || n - p != tl) {
		return false;
	}
	if (tl) {
		if (!ticket_text_ok((const char*) b + p, tl)) {
			return false;
		}
		memcpy(h->ticket, b + p, tl);
	}
	return true;
}

size_t coop_message_encode(int type, const uint8_t* payload, size_t n, uint8_t* out) {
	out[0] = (uint8_t) (type >> 8);
	out[1] = (uint8_t) type;
	if (n) {
		memcpy(out + 2, payload, n);
	}
	return n + 2;
}

int coop_message_decode(const uint8_t* frame, size_t n, const uint8_t** payload, size_t* payloadLen) {
	if (n < 2 || n > 65536) {
		return 0;
	}
	*payload = frame + 2;
	*payloadLen = n - 2;
	return frame[0] << 8 | frame[1];
}

/* ---- tickets ---- */

static const char B32[] = "abcdefghijklmnopqrstuvwxyz234567";

void coop_ticket_encode(const coop_ticket* t, char* out, size_t outSize) {
	uint8_t raw[1 + 32 + 1 + 16 + 1 + 4 * 19];
	size_t n = 0;
	raw[n++] = 1;
	memcpy(raw + n, t->peer, 32);
	n += 32;
	raw[n++] = t->hasSecret ? 1 : 0;
	if (t->hasSecret) {
		memcpy(raw + n, t->secret, 16);
		n += 16;
	}
	int count = t->count < 0 ? 0 : t->count > 4 ? 4 : t->count;
	raw[n++] = (uint8_t) count;
	for (int i = 0; i < count; i++) {
		const coop_address* a = &t->addresses[i];
		int len = a->family == 6 ? 16 : 4;
		raw[n++] = (uint8_t) (a->family == 6 ? 6 : 4);
		memcpy(raw + n, a->addr, (size_t) len);
		n += (size_t) len;
		raw[n++] = (uint8_t) (a->port >> 8);
		raw[n++] = (uint8_t) a->port;
	}
	size_t o = 0;
	if (outSize < 5) {
		return;
	}
	memcpy(out, "pdco", 4);
	o = 4;
	unsigned acc = 0;
	int bits = 0;
	for (size_t i = 0; i < n && o + 1 < outSize; i++) {
		acc = (acc << 8) | raw[i];
		bits += 8;
		while (bits >= 5 && o + 1 < outSize) {
			out[o++] = B32[(acc >> (bits - 5)) & 31];
			bits -= 5;
		}
		acc &= (1u << bits) - 1;
	}
	if (bits > 0 && o + 1 < outSize) {
		out[o++] = B32[(acc << (5 - bits)) & 31];
	}
	out[o] = 0;
}

bool coop_ticket_decode(const char* text, coop_ticket* t) {
	memset(t, 0, sizeof *t);
	if (!text || strlen(text) > 4096) {
		return false;
	}
	while (isspace((unsigned char) *text)) {
		text++;
	}
	size_t len = strlen(text);
	while (len && isspace((unsigned char) text[len - 1])) {
		len--;
	}
	static const char SCHEME[] = "pokedaisy://";
	bool scheme = len >= sizeof SCHEME - 1;
	for (size_t i = 0; scheme && i < sizeof SCHEME - 1; i++) {
		scheme = tolower((unsigned char) text[i]) == SCHEME[i];
	}
	if (scheme) {
		text += sizeof SCHEME - 1;
		len -= sizeof SCHEME - 1;
		if (len < 5 || strncmp(text, "coop/", 5)) {
			return false;
		}
		text += 5;
		len -= 5;
	}
	if (!ticket_text_ok(text, len)) {
		return false;
	}
	uint8_t raw[200];
	size_t n = 0;
	unsigned acc = 0;
	int bits = 0;
	for (size_t i = 4; i < len; i++) {
		const char* at = strchr(B32, text[i]);
		if (!at) {
			return false;
		}
		acc = (acc << 5) | (unsigned) (at - B32);
		bits += 5;
		if (bits >= 8) {
			if (n == sizeof raw) {
				return false;
			}
			raw[n++] = (uint8_t) (acc >> (bits - 8));
			bits -= 8;
			acc &= (1u << bits) - 1;
		}
	}
	if (bits >= 5 || acc) {
		return false;
	}
	size_t i = 0;
	if (n < 1 || raw[i++] != 1 || n - i < 32) {
		return false;
	}
	memcpy(t->peer, raw + i, 32);
	i += 32;
	if (n - i < 1) {
		return false;
	}
	uint8_t flags = raw[i++];
	if (flags & ~1u) {
		return false;
	}
	if (flags & 1) {
		if (n - i < 16) {
			return false;
		}
		t->hasSecret = true;
		memcpy(t->secret, raw + i, 16);
		i += 16;
	}
	if (n - i < 1) {
		return false;
	}
	int count = raw[i++];
	if (count > 4) {
		return false;
	}
	for (int k = 0; k < count; k++) {
		if (n - i < 1) {
			return false;
		}
		int fam = raw[i++];
		size_t al = fam == 4 ? 4 : fam == 6 ? 16 : 0;
		if (!al || n - i < al + 2) {
			return false;
		}
		t->addresses[k].family = fam;
		memcpy(t->addresses[k].addr, raw + i, al);
		i += al;
		t->addresses[k].port = (uint16_t) (raw[i] << 8 | raw[i + 1]);
		i += 2;
		if (!t->addresses[k].port) {
			return false;
		}
	}
	t->count = count;
	return i == n;
}

void coop_peer_hex(const uint8_t peer[32], char out[65]) {
	for (int i = 0; i < 32; i++) {
		out[2 * i] = HEX[peer[i] >> 4];
		out[2 * i + 1] = HEX[peer[i] & 15];
	}
	out[64] = 0;
}

static int hexval(char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

bool coop_peer_parse(const char* hex, uint8_t out[32]) {
	if (!hex || strlen(hex) != 64) {
		return false;
	}
	for (int i = 0; i < 32; i++) {
		int hi = hexval(hex[2 * i]), lo = hexval(hex[2 * i + 1]);
		if (hi < 0 || lo < 0 || (hex[2 * i] >= 'A' && hex[2 * i] <= 'F') || (hex[2 * i + 1] >= 'A' && hex[2 * i + 1] <= 'F')) {
			return false;
		}
		out[i] = (uint8_t) (hi << 4 | lo);
	}
	return true;
}

void coop_lan_user_data(const coop_save_id* s, char* out, size_t outSize) {
	char name[17];
	for (int i = 0; i < 8; i++) {
		name[2 * i] = HEX[s->name[i] >> 4];
		name[2 * i + 1] = HEX[s->name[i] & 15];
	}
	name[16] = 0;
	snprintf(out, outSize, "pokedaisy-coop/1;%s;%u", name, s->trainerId);
}

bool coop_lan_parse(const char* u, uint8_t name[8], int* trainerId) {
	static const char PREFIX[] = "pokedaisy-coop/1;";
	if (!u || strncmp(u, PREFIX, sizeof PREFIX - 1)) {
		return false;
	}
	const char* hex = u + sizeof PREFIX - 1;
	const char* semi = strchr(hex, ';');
	if (!semi) {
		return false;
	}
	size_t hl = (size_t) (semi - hex);
	if (!hl || hl > 16 || hl % 2) {
		return false;
	}
	memset(name, 0xFF, 8);
	for (size_t i = 0; i < hl / 2; i++) {
		int hi = hexval(hex[2 * i]), lo = hexval(hex[2 * i + 1]);
		if (hi < 0 || lo < 0) {
			return false;
		}
		name[i] = (uint8_t) (hi << 4 | lo);
	}
	const char* id = semi + 1;
	if (!*id || strchr(id, ';')) {
		return false;
	}
	char* end;
	long v = strtol(id, &end, 10);
	if (*end) {
		return false;
	}
	*trainerId = (int) v;
	return true;
}

bool coop_rom_accepted(const uint8_t sha1[20]) {
	static const uint8_t ACCEPTED[][20] = {
	    /* English Emerald (USA, Europe) */
	    {0xf3, 0xae, 0x08, 0x81, 0x81, 0xbf, 0x58, 0x3e, 0x55, 0xda, 0xf9, 0x62, 0xa9, 0x2b, 0xb4, 0x6f, 0x4f, 0x1d, 0x07, 0xb7},
	    /* French Emerald (Pokémon Version Émeraude) */
	    {0xca, 0x66, 0x66, 0x51, 0x37, 0x4d, 0x89, 0xca, 0x43, 0x90, 0x07, 0xbe, 0xd5, 0x4d, 0x83, 0x9e, 0xb7, 0xbd, 0x14, 0xd0},
	    /* Seeing each other only (the joined battles and trades are Emerald's): FireRed / LeafGreen, English 1.0 and French */
	    /* FireRed (USA, Europe) */
	    {0x41, 0xcb, 0x23, 0xd8, 0xdc, 0xcc, 0x8e, 0xbd, 0x7c, 0x64, 0x9c, 0xd8, 0xfb, 0xb5, 0x8e, 0xea, 0xce, 0x6e, 0x2f, 0xdc},
	    /* LeafGreen (USA, Europe) */
	    {0x57, 0x4f, 0xa5, 0x42, 0xff, 0xeb, 0xb1, 0x4b, 0xe6, 0x99, 0x02, 0xd1, 0xd3, 0x6f, 0x1e, 0xc0, 0xa4, 0xaf, 0xd7, 0x1e},
	    /* French FireRed (Pokémon Version Rouge Feu) */
	    {0xfc, 0x66, 0x39, 0x07, 0x25, 0x6f, 0x06, 0xa3, 0xa0, 0x9e, 0x2d, 0x6b, 0x96, 0x7b, 0xc9, 0xaf, 0x49, 0x19, 0xf1, 0x11},
	    /* French LeafGreen (Pokémon Version Vert Feuille) */
	    {0x4b, 0x57, 0x58, 0xc1, 0x4d, 0x0a, 0x07, 0xb7, 0x0e, 0xf3, 0xef, 0x0b, 0xd7, 0xfa, 0x5e, 0x7c, 0xe6, 0x97, 0x86, 0x72},
	};
	for (size_t i = 0; i < sizeof ACCEPTED / sizeof ACCEPTED[0]; i++) {
		if (!memcmp(sha1, ACCEPTED[i], 20)) {
			return true;
		}
	}
	return false;
}
