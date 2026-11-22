/* PokeDaisy's co-op link for Capsule (iPhone, PC): the transport over TCP connections the frontend owns, pairing two
 * saves and the link to a paired partner, ported from the Android app (RelayCoopTransport's TCP path, CoopPairing,
 * CoopLinkImpl) so the devices understand each other. Same Wi-Fi or a ticket's addresses; no relay yet.
 *
 * The frontend opens a TCP listener and advertises it on the LAN (Bonjour `_pdcoop._tcp`, name coop_host_lan_name, TXT
 * k = coop_host_peer_hex, u = coop_host_lan_user_data when not empty), browses for the same service (coop_host_lan_seen /
 * _lost), and moves bytes: coop_host_accepted / _dialed / _data / _gone in, coop_io's write / close / dial out. Every call
 * on one thread; `now` is a monotonic clock in ms. Licensed under the GNU GPL v3. */
#ifndef COOP_HOST_H
#define COOP_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "coop_wire.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct coop_host coop_host;

typedef struct {
	void* ctx;
	/* Raw bytes on a connection (the host adds TCP framing). False = it's gone. */
	bool (*write)(void* ctx, int conn, const uint8_t* bytes, size_t n);
	void (*close)(void* ctx, int conn);
	/* Starts a TCP connection (IPv4 / IPv6 bytes, a port): its id, the same id space as accepted ones, or -1. Its outcome
	 * comes back through coop_host_dialed. */
	int (*dial)(void* ctx, const coop_address* address);
	/* A presence update from the partner (the game's core takes it). */
	void (*presence)(void* ctx, const uint8_t* bytes, size_t n);
	/* A joined-battle message from the partner (types 0x0200-0x02FF: the game's core takes it); NULL = dropped. */
	void (*message)(void* ctx, int type, const uint8_t* bytes, size_t n);
} coop_io;

coop_host* coop_host_new(const uint8_t secret[32], const char* pairsPath, const char* appVersion, coop_io io);
void coop_host_free(coop_host* h);

void coop_host_peer_hex(const coop_host* h, char out[65]);
/* "pdco-" + the key's first 12 hex characters. */
void coop_host_lan_name(const coop_host* h, char out[18]);
/* What to advertise as TXT `u` ("" = nothing: pairing is closed). */
void coop_host_lan_user_data(const coop_host* h, char* out, size_t outSize);
/* This device's LAN addresses (and the listener's port): they go into its ticket. */
void coop_host_set_addresses(coop_host* h, const coop_address* addresses, int count);
/* This device's ticket, for a link / QR code ("" until addresses are known). */
void coop_host_ticket(const coop_host* h, char* out, size_t outSize);

/* The game being played (or picked to pair): its ROM's SHA-1 and its battery save. False when co-op can't use it (not
 * an Emerald it accepts, or no trainer in the save yet). */
bool coop_host_set_game(coop_host* h, const uint8_t romSha1[20], const uint8_t* save, size_t saveLen);
/* The same with the save already read (tests). */
bool coop_host_set_game_id(coop_host* h, const uint8_t romSha1[20], const coop_save_id* save, bool female);

/* ---- the frontend's connections and LAN ---- */
void coop_host_accepted(coop_host* h, int conn, int64_t now);
void coop_host_dialed(coop_host* h, int conn, bool ok, int64_t now);
void coop_host_data(coop_host* h, int conn, const uint8_t* bytes, size_t n, int64_t now);
void coop_host_gone(coop_host* h, int conn, int64_t now);
/* A service resolved on the LAN: its TXT k and u, and an address. */
void coop_host_lan_seen(coop_host* h, const char* keyHex, const char* userData, const coop_address* address);
void coop_host_lan_lost(coop_host* h, const char* keyHex);
/* Every 100-250 ms. */
void coop_host_tick(coop_host* h, int64_t now);

/* ---- pairing ---- */
enum {
	COOP_PAIR_IDLE,
	COOP_PAIR_INVITING,   /* waiting for someone to join; nearby devices listed */
	COOP_PAIR_CONNECTING,
	COOP_PAIR_CONFIRM,    /* accept this player? */
	COOP_PAIR_WAITING,    /* we said yes, the other hasn't yet */
	COOP_PAIR_PAIRED,
	COOP_PAIR_FAILED
};
enum {
	COOP_FAIL_NONE,
	COOP_FAIL_VERSION,
	COOP_FAIL_DIFFERENT_ROM,
	COOP_FAIL_SAME_SAVE,
	COOP_FAIL_SAVE_ALREADY_PAIRED,
	COOP_FAIL_DENIED,
	COOP_FAIL_NETWORK,
	COOP_FAIL_TIMEOUT,
	COOP_FAIL_BAD_INVITE,
	COOP_FAIL_NO_GAME
};

void coop_pair_open(coop_host* h, int64_t now);
bool coop_pair_join_lan(coop_host* h, const char* keyHex, int64_t now);
bool coop_pair_join_ticket(coop_host* h, const char* ticketOrLink, int64_t now);
void coop_pair_accept(coop_host* h, int64_t now);
void coop_pair_deny(coop_host* h, int64_t now);
void coop_pair_close(coop_host* h);
int coop_pair_step(const coop_host* h);
int coop_pair_fail(const coop_host* h);
/* The other player (CONFIRM and after): name (UTF-8), trainer ID. */
void coop_pair_partner(const coop_host* h, char* name, size_t nameSize, int* trainerId);
/* The devices offering to pair nearby (INVITING): count, then each one's key and label. */
int coop_pair_nearby_count(const coop_host* h);
void coop_pair_nearby(const coop_host* h, int i, char keyHex[65], char* label, size_t labelSize);

/* ---- the pairs kept ---- */
int coop_pairs_count(const coop_host* h);
/* The i-th pair: the partner's name (UTF-8) and whether it is the current game's save's pair. */
void coop_pairs_get(const coop_host* h, int i, char* partnerName, size_t nameSize, bool* current);
void coop_pairs_remove(coop_host* h, int i);
/* The current game's save has a partner. */
bool coop_pairs_has_current(const coop_host* h);

/* ---- the link to the partner while playing ---- */
enum { COOP_LINK_OFF, COOP_LINK_CONNECTING, COOP_LINK_CONNECTED, COOP_LINK_DISCONNECTED };
void coop_link_start(coop_host* h, int64_t now);
void coop_link_stop(coop_host* h);
int coop_link_state(const coop_host* h);
void coop_link_partner(const coop_host* h, char* name, size_t nameSize);
/* A presence update to the partner; false unless connected. */
bool coop_link_send_presence(coop_host* h, const uint8_t* bytes, size_t n);
/* A joined-battle message (types 0x0200-0x02FF, the Android app's CoopBattleWire); false unless connected. */
#define COOP_BATTLE_FIRST_TYPE 0x0200
#define COOP_BATTLE_LAST_TYPE 0x02FF
bool coop_link_send(coop_host* h, int type, const uint8_t* bytes, size_t n);

#ifdef __cplusplus
}
#endif

#endif
