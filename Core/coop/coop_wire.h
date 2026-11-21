/* PokeDaisy's co-op link, its messages (CoopWire.kt, CoopTicket.kt, CoopModel.kt): the same bytes on the wire, so an
 * iPhone, a PC and the Android app pair and play together. Licensed under the GNU GPL v3. */
#ifndef COOP_WIRE_H
#define COOP_WIRE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define COOP_PROTOCOL 1
#define COOP_FIRST_APP_TYPE 0x0100
#define COOP_PRESENCE_TYPE 0x0100
enum { COOP_MSG_HELLO = 1, COOP_MSG_PAIR_ACCEPT = 2, COOP_MSG_PAIR_DENY = 3, COOP_MSG_BYE = 4 };

/* A save, as co-op tells them apart: trainer ID, secret ID and the 8 raw name bytes. */
typedef struct {
	uint16_t trainerId, secretId;
	uint8_t name[8];
} coop_save_id;

bool coop_save_equal(const coop_save_id* a, const coop_save_id* b);
/* "%04x%04x-" + the name's hex: 26 characters + NUL. */
void coop_save_key(const coop_save_id* s, char out[27]);

typedef struct {
	int protocol;
	char appVersion[33];
	uint8_t romSha1[20];
	coop_save_id save;
	bool female;
	char ticket[2049]; /* "" = none */
} coop_hello;

/* The HELLO's bytes into out (room for 2 + 1 + 32 + 20 + 12 + 1 + 2 + 2048): their count. */
size_t coop_hello_encode(const coop_hello* h, uint8_t* out);
/* False on anything out of range, short, overlong or past the ticket. */
bool coop_hello_decode(const uint8_t* b, size_t n, coop_hello* h);

/* An app message: a u16 big-endian type and the payload. */
size_t coop_message_encode(int type, const uint8_t* payload, size_t n, uint8_t* out);
/* The type (0 = not a message) and where the payload starts. */
int coop_message_decode(const uint8_t* frame, size_t n, const uint8_t** payload, size_t* payloadLen);

/* A ticket: "pdco" + base32 of version 1, the 32-byte key, flags (bit 0: a 16-byte invite secret follows), up to four
 * addresses (family 4 or 6, the bytes, a u16 port). */
typedef struct {
	int family; /* 4 or 6 */
	uint8_t addr[16];
	uint16_t port;
} coop_address;

typedef struct {
	uint8_t peer[32];
	bool hasSecret;
	uint8_t secret[16];
	int count;
	coop_address addresses[4];
} coop_ticket;

/* The text (room for 4 + 167 + 1). */
void coop_ticket_encode(const coop_ticket* t, char* out, size_t outSize);
/* Also takes a "pokedaisy://coop/<ticket>" link. */
bool coop_ticket_decode(const char* text, coop_ticket* t);

/* A peer id as 64 lowercase hex characters, and back. */
void coop_peer_hex(const uint8_t peer[32], char out[65]);
bool coop_peer_parse(const char* hex, uint8_t out[32]);

/* The LAN advertisement's user data: "pokedaisy-coop/1;<name hex>;<trainer id>". */
void coop_lan_user_data(const coop_save_id* s, char* out, size_t outSize);
/* The name bytes and trainer ID in such user data; false for any other text. */
bool coop_lan_parse(const char* userData, uint8_t name[8], int* trainerId);

/* A ROM's SHA-1 Emerald co-op accepts (retail Emerald, English or French: the same maps and field RAM). */
bool coop_rom_accepted(const uint8_t sha1[20]);

#ifdef __cplusplus
}
#endif

#endif
