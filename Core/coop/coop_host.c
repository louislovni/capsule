/* PokeDaisy's co-op link for Capsule (coop_host.h). Licensed under the GNU GPL v3. */
#include "coop_host.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "coop_crypto.h"
#include "coop_noise.h"
#include "pkcore.h"

#define MAX_CONNS 24
#define MAX_PAIRS 16
#define MAX_LAN 16
#define MAX_ALLOWED 16
#define DUPLICATE_WINDOW_MS 5000
#define PENDING_MS 60000
#define PENDING_FRAMES 8
#define PENDING_BYTES 2048
#define HELLO_TIMEOUT_MS 10000
#define CONFIRM_TIMEOUT_MS 60000
#define BACKOFF_START_MS 1000
#define BACKOFF_MAX_MS 30000

typedef struct {
	bool used, outgoing, tcpUp, registered, pending;
	int id;
	uint8_t expect[32];
	coop_channel ch;
	uint8_t* rx;
	size_t rxLen, rxCap;
	int pendingFrames;
	int64_t pendingSince;
} conn_t;

typedef struct {
	uint8_t peer[32];
	char userData[201];
	bool hasAddr;
	coop_address addr;
} lan_t;

typedef struct {
	coop_save_id own, partnerSave;
	uint8_t partner[32];
	bool female;
	char ticket[300];
	long long pairedAt;
} pair_t;

struct coop_host {
	uint8_t secret[32], pub[32];
	coop_io io;
	char pairsPath[1024], appVersion[33];
	conn_t conns[MAX_CONNS];
	lan_t lan[MAX_LAN];
	int nlan;
	pair_t pairs[MAX_PAIRS];
	int npairs;
	coop_address addrs[4];
	int naddr;
	// the game
	bool haveGame, female;
	uint8_t rom[20];
	coop_save_id save;
	// the policy
	uint8_t allowed[MAX_ALLOWED][32];
	int nallowed;
	bool pairingOpen;
	uint8_t accepted[MAX_ALLOWED][32];
	int naccepted;
	// a dial under way
	bool dialing;
	uint8_t dialPeer[32];
	// pairing
	int step, fail;
	bool pairOpened, joining, iAccepted, theyAccepted, havePeer, haveTheirHello;
	uint8_t peer[32];
	coop_hello theirHello;
	struct {
		bool used, pending;
		uint8_t peer[32];
		int64_t deadline;
	} candidates[4];
	int64_t confirmDeadline;
	// the link
	int linkState;
	int linkPair; // -1 none
	bool live, helloOk;
	int64_t helloDeadline, retryAt;
	int64_t backoff;
};

/* ---- helpers ---- */

static bool key_eq(const uint8_t* a, const uint8_t* b) { return !memcmp(a, b, 32); }

static int key_cmp(const uint8_t* a, const uint8_t* b) { return memcmp(a, b, 32); }

static conn_t* conn_of(coop_host* h, int id) {
	for (int i = 0; i < MAX_CONNS; i++) {
		if (h->conns[i].used && h->conns[i].id == id) {
			return &h->conns[i];
		}
	}
	return NULL;
}

static conn_t* registered(coop_host* h, const uint8_t peer[32]) {
	for (int i = 0; i < MAX_CONNS; i++) {
		conn_t* c = &h->conns[i];
		if (c->used && c->registered && !c->ch.done && key_eq(c->ch.remote, peer)) {
			return c;
		}
	}
	return NULL;
}

static bool in_list(uint8_t list[][32], int n, const uint8_t* k) {
	for (int i = 0; i < n; i++) {
		if (key_eq(list[i], k)) {
			return true;
		}
	}
	return false;
}

static void free_conn(coop_host* h, conn_t* c, bool closeSocket) {
	if (closeSocket && h->io.close) {
		h->io.close(h->io.ctx, c->id);
	}
	free(c->rx);
	memset(c, 0, sizeof *c);
}

/* A ticket (at most 4 + 205 characters, checked when it was decoded) into a pair's field. */
static void set_ticket(char dst[300], const char* src) {
	size_t n = strlen(src);
	if (n >= 300) {
		n = 0;
	}
	memcpy(dst, src, n);
	dst[n] = 0;
}

static void name_utf8(const uint8_t name[8], char* out, size_t size) { pk_text_decode(name, 7, out, size); }

/* ---- the pairs file ---- */

static void pairs_save(coop_host* h) {
	if (!h->pairsPath[0]) {
		return;
	}
	char tmp[1100];
	snprintf(tmp, sizeof tmp, "%s.tmp", h->pairsPath);
	FILE* f = fopen(tmp, "w");
	if (!f) {
		return;
	}
	for (int i = 0; i < h->npairs; i++) {
		pair_t* p = &h->pairs[i];
		char own[27], partner[65], pname[17];
		coop_save_key(&p->own, own);
		coop_peer_hex(p->partner, partner);
		for (int k = 0; k < 8; k++) {
			snprintf(pname + 2 * k, 3, "%02x", p->partnerSave.name[k]);
		}
		fprintf(f, "%s\t%s\t%u\t%u\t%s\t%d\t%s\t%lld\n", own, partner, p->partnerSave.trainerId, p->partnerSave.secretId,
		        pname, p->female ? 1 : 0, p->ticket[0] ? p->ticket : "-", p->pairedAt);
	}
	fclose(f);
	rename(tmp, h->pairsPath);
}

static bool parse_save_key(const char* key, coop_save_id* s) {
	unsigned tid, sid;
	if (strlen(key) != 25 || sscanf(key, "%4x%4x-", &tid, &sid) != 2) {
		return false;
	}
	s->trainerId = (uint16_t) tid;
	s->secretId = (uint16_t) sid;
	for (int i = 0; i < 8; i++) {
		unsigned v;
		if (sscanf(key + 9 + 2 * i, "%2x", &v) != 1) {
			return false;
		}
		s->name[i] = (uint8_t) v;
	}
	return true;
}

static void pairs_load(coop_host* h) {
	h->npairs = 0;
	FILE* f = h->pairsPath[0] ? fopen(h->pairsPath, "r") : NULL;
	if (!f) {
		return;
	}
	char line[1024];
	while (h->npairs < MAX_PAIRS && fgets(line, sizeof line, f)) {
		char own[64], partner[80], pname[40], ticket[400];
		unsigned tid, sid;
		int female;
		long long at;
		if (sscanf(line, "%63s\t%79s\t%u\t%u\t%39s\t%d\t%399s\t%lld", own, partner, &tid, &sid, pname, &female, ticket, &at) != 8) {
			continue;
		}
		pair_t p;
		memset(&p, 0, sizeof p);
		if (!parse_save_key(own, &p.own) || !coop_peer_parse(partner, p.partner) || strlen(pname) != 16) {
			continue;
		}
		p.partnerSave.trainerId = (uint16_t) tid;
		p.partnerSave.secretId = (uint16_t) sid;
		for (int i = 0; i < 8; i++) {
			unsigned v;
			sscanf(pname + 2 * i, "%2x", &v);
			p.partnerSave.name[i] = (uint8_t) v;
		}
		p.female = female == 1;
		if (strcmp(ticket, "-")) {
			set_ticket(p.ticket, ticket);
		}
		p.pairedAt = at;
		h->pairs[h->npairs++] = p;
	}
	fclose(f);
}

static int pair_for_save(const coop_host* h, const coop_save_id* s) {
	for (int i = 0; i < h->npairs; i++) {
		if (coop_save_equal(&h->pairs[i].own, s)) {
			return i;
		}
	}
	return -1;
}

/* ---- the transport ---- */

static void on_connected(coop_host* h, const uint8_t peer[32], bool pending, int64_t now);
static void on_frame(coop_host* h, const uint8_t peer[32], const uint8_t* b, size_t n, int64_t now);
static void on_disconnected(coop_host* h, const uint8_t peer[32], int code, int64_t now);
static void on_dial_failed(coop_host* h, int code, int64_t now);

static int64_t sNow; // the time of the call being handled (the channel's callbacks have none)

static bool ch_pipe(void* ctx, coop_channel* ch, const uint8_t* b, size_t n) {
	coop_host* h = ctx;
	conn_t* c = (conn_t*) ((char*) ch - offsetof(conn_t, ch));
	if (!h->io.write || n > COOP_MAX_TCP_FRAME) {
		return false;
	}
	uint8_t* out = malloc(n + 4);
	if (!out) {
		return false;
	}
	out[0] = (uint8_t) (n >> 24);
	out[1] = (uint8_t) (n >> 16);
	out[2] = (uint8_t) (n >> 8);
	out[3] = (uint8_t) n;
	memcpy(out + 4, b, n);
	bool ok = h->io.write(h->io.ctx, c->id, out, n + 4);
	free(out);
	return ok;
}

static int ch_decide(void* ctx, coop_channel* ch, const uint8_t remote[32]) {
	coop_host* h = ctx;
	conn_t* c = (conn_t*) ((char*) ch - offsetof(conn_t, ch));
	if (in_list(h->allowed, h->nallowed, remote)) {
		return 0;
	}
	if (h->pairingOpen) {
		c->pending = true;
		return 0;
	}
	return COOP_NOT_ALLOWED;
}

static uint8_t initiator_key_buf[32];
static const uint8_t* initiator_key(coop_host* h, conn_t* c) {
	if (c->outgoing) {
		return h->pub;
	}
	memcpy(initiator_key_buf, c->ch.remote, 32);
	return initiator_key_buf;
}

static void ch_opened(void* ctx, coop_channel* ch, const uint8_t remote[32]) {
	coop_host* h = ctx;
	conn_t* c = (conn_t*) ((char*) ch - offsetof(conn_t, ch));
	conn_t* old = registered(h, remote);
	if (old && old != c) {
		bool keepOld;
		if (sNow - old->ch.openedAt < DUPLICATE_WINDOW_MS) {
			uint8_t oldKey[32], newKey[32];
			memcpy(oldKey, initiator_key(h, old), 32);
			memcpy(newKey, initiator_key(h, c), 32);
			keepOld = key_cmp(oldKey, newKey) <= 0;
		} else {
			keepOld = false;
		}
		conn_t* loser = keepOld ? c : old;
		coop_channel_close(&loser->ch, COOP_DUPLICATE);
		loser->registered = false;
		free_conn(h, loser, true);
		if (keepOld) {
			return;
		}
	}
	c->registered = true;
	if (in_list(h->accepted, h->naccepted, remote)) {
		c->pending = false;
	}
	if (c->pending) {
		c->pendingSince = sNow;
	}
	if (c->outgoing && h->dialing && key_eq(h->dialPeer, remote)) {
		h->dialing = false;
		// The other attempts of this dial go.
		for (int i = 0; i < MAX_CONNS; i++) {
			conn_t* o = &h->conns[i];
			if (o->used && o != c && o->outgoing && !o->registered && key_eq(o->expect, remote)) {
				coop_channel_close(&o->ch, COOP_DUPLICATE);
				free_conn(h, o, true);
			}
		}
	}
	uint8_t peer[32];
	memcpy(peer, remote, 32);
	on_connected(h, peer, c->pending, sNow);
}

static void ch_frame(void* ctx, coop_channel* ch, const uint8_t* b, size_t n) {
	coop_host* h = ctx;
	conn_t* c = (conn_t*) ((char*) ch - offsetof(conn_t, ch));
	if (!c->registered) {
		return;
	}
	if (c->pending && (++c->pendingFrames > PENDING_FRAMES || n > PENDING_BYTES)) {
		uint8_t peer[32];
		memcpy(peer, ch->remote, 32);
		coop_channel_close(&c->ch, COOP_OVERFLOW);
		free_conn(h, c, true);
		on_disconnected(h, peer, COOP_OVERFLOW, sNow);
		return;
	}
	uint8_t peer[32];
	memcpy(peer, ch->remote, 32);
	on_frame(h, peer, b, n, sNow);
}

static bool dial_still_going(coop_host* h) {
	for (int i = 0; i < MAX_CONNS; i++) {
		conn_t* o = &h->conns[i];
		if (o->used && o->outgoing && !o->registered && !o->ch.done && key_eq(o->expect, h->dialPeer)) {
			return true;
		}
	}
	return false;
}

/* The connection [c] ended (its channel closed or the socket went): reported once, freed. */
static void conn_ended(coop_host* h, conn_t* c, int code, bool closeSocket) {
	bool wasRegistered = c->registered, outgoing = c->outgoing;
	uint8_t peer[32];
	memcpy(peer, c->registered ? c->ch.remote : c->expect, 32);
	c->registered = false;
	free_conn(h, c, closeSocket);
	if (wasRegistered) {
		on_disconnected(h, peer, code, sNow);
	} else if (outgoing && h->dialing && key_eq(h->dialPeer, peer) && !dial_still_going(h)) {
		h->dialing = false;
		on_dial_failed(h, code, sNow);
	}
}

static void ch_closed(void* ctx, coop_channel* ch, int code, bool beforeOpen) {
	(void) beforeOpen;
	coop_host* h = ctx;
	conn_t* c = (conn_t*) ((char*) ch - offsetof(conn_t, ch));
	conn_ended(h, c, code, true);
}

static coop_channel_events channel_events(coop_host* h) {
	coop_channel_events ev = {h, ch_pipe, ch_decide, ch_opened, ch_frame, ch_closed};
	return ev;
}

static conn_t* new_conn(coop_host* h, int id) {
	for (int i = 0; i < MAX_CONNS; i++) {
		if (!h->conns[i].used) {
			memset(&h->conns[i], 0, sizeof h->conns[i]);
			h->conns[i].used = true;
			h->conns[i].id = id;
			return &h->conns[i];
		}
	}
	return NULL;
}

void coop_host_accepted(coop_host* h, int conn, int64_t now) {
	sNow = now;
	conn_t* c = new_conn(h, conn);
	if (!c) {
		if (h->io.close) h->io.close(h->io.ctx, conn);
		return;
	}
	c->tcpUp = true;
	uint8_t pro[64];
	size_t pl = coop_prologue(COOP_PATH_TCP, NULL, pro);
	coop_channel_init(&c->ch, false, h->secret, NULL, pro, pl, now, channel_events(h));
}

void coop_host_dialed(coop_host* h, int conn, bool ok, int64_t now) {
	sNow = now;
	conn_t* c = conn_of(h, conn);
	if (!c) {
		return;
	}
	if (!ok) {
		conn_ended(h, c, COOP_ERROR, false);
		return;
	}
	c->tcpUp = true;
	c->ch.startedAt = now;
	coop_channel_begin(&c->ch);
}

void coop_host_data(coop_host* h, int conn, const uint8_t* bytes, size_t n, int64_t now) {
	sNow = now;
	conn_t* c = conn_of(h, conn);
	if (!c || !n) {
		return;
	}
	if (c->rxLen + n > c->rxCap) {
		size_t cap = c->rxCap ? c->rxCap : 4096;
		while (cap < c->rxLen + n) cap *= 2;
		uint8_t* rx = realloc(c->rx, cap);
		if (!rx) {
			return;
		}
		c->rx = rx;
		c->rxCap = cap;
	}
	memcpy(c->rx + c->rxLen, bytes, n);
	c->rxLen += n;
	int id = c->id;
	while ((c = conn_of(h, id)) && c->rxLen >= 4) {
		size_t len = (size_t) c->rx[0] << 24 | (size_t) c->rx[1] << 16 | (size_t) c->rx[2] << 8 | c->rx[3];
		if (len > COOP_MAX_TCP_FRAME) {
			coop_channel_close(&c->ch, COOP_ERROR);
			conn_ended(h, c, COOP_ERROR, true);
			return;
		}
		if (c->rxLen < len + 4) {
			break;
		}
		uint8_t* msg = malloc(len ? len : 1);
		if (!msg) {
			return;
		}
		memcpy(msg, c->rx + 4, len);
		memmove(c->rx, c->rx + 4 + len, c->rxLen - 4 - len);
		c->rxLen -= 4 + len;
		coop_channel_receive(&c->ch, msg, len, now);
		free(msg);
	}
}

void coop_host_gone(coop_host* h, int conn, int64_t now) {
	sNow = now;
	conn_t* c = conn_of(h, conn);
	if (!c) {
		return;
	}
	if (!c->ch.done) {
		c->ch.done = true;
	}
	conn_ended(h, c, COOP_ERROR, false);
}

static void set_policy(coop_host* h, const uint8_t (*allowed)[32], int n, bool pairingOpen) {
	h->nallowed = n > MAX_ALLOWED ? MAX_ALLOWED : n;
	for (int i = 0; i < h->nallowed; i++) {
		memcpy(h->allowed[i], allowed[i], 32);
	}
	h->pairingOpen = pairingOpen;
}

static void accept_peer(coop_host* h, const uint8_t peer[32]) {
	conn_t* c = registered(h, peer);
	if (c) {
		c->pending = false;
	}
	if (!in_list(h->accepted, h->naccepted, peer) && h->naccepted < MAX_ALLOWED) {
		memcpy(h->accepted[h->naccepted++], peer, 32);
	}
}

/* Ends the connection to [peer] with [code] (told to the peer), reporting nothing here. */
static void disconnect_peer(coop_host* h, const uint8_t peer[32], int code) {
	for (int i = 0; i < MAX_CONNS; i++) {
		conn_t* c = &h->conns[i];
		if (c->used && ((c->registered && key_eq(c->ch.remote, peer)) || (c->outgoing && !c->registered && key_eq(c->expect, peer)))) {
			coop_channel_close(&c->ch, code);
			free_conn(h, c, true);
		}
	}
	if (h->dialing && key_eq(h->dialPeer, peer)) {
		h->dialing = false;
	}
}

static bool send_to(coop_host* h, const uint8_t peer[32], int type, const uint8_t* payload, size_t n) {
	conn_t* c = registered(h, peer);
	if (!c || c->pending) {
		return false;
	}
	uint8_t* frame = malloc(n + 2);
	if (!frame) {
		return false;
	}
	size_t len = coop_message_encode(type, payload, n, frame);
	bool ok = coop_channel_send(&c->ch, frame, len);
	free(frame);
	return ok;
}

static const lan_t* lan_of(const coop_host* h, const uint8_t peer[32]) {
	for (int i = 0; i < h->nlan; i++) {
		if (key_eq(h->lan[i].peer, peer)) {
			return &h->lan[i];
		}
	}
	return NULL;
}

/* Dials [peer] at the ticket's addresses and its LAN one: false when there's nowhere to dial. */
static bool dial(coop_host* h, const uint8_t peer[32], const coop_ticket* t, int64_t now) {
	if (!h->io.dial || registered(h, peer)) {
		return registered(h, peer) != NULL;
	}
	coop_address list[5];
	int n = 0;
	const lan_t* l = lan_of(h, peer);
	if (l && l->hasAddr) {
		list[n++] = l->addr;
	}
	for (int i = 0; t && i < t->count && n < 5; i++) {
		list[n++] = t->addresses[i];
	}
	if (!n) {
		return false;
	}
	h->dialing = true;
	memcpy(h->dialPeer, peer, 32);
	int started = 0;
	for (int i = 0; i < n; i++) {
		int id = h->io.dial(h->io.ctx, &list[i]);
		if (id < 0) {
			continue;
		}
		conn_t* c = new_conn(h, id);
		if (!c) {
			if (h->io.close) h->io.close(h->io.ctx, id);
			continue;
		}
		c->outgoing = true;
		memcpy(c->expect, peer, 32);
		uint8_t pro[64];
		size_t pl = coop_prologue(COOP_PATH_TCP, NULL, pro);
		coop_channel_init(&c->ch, true, h->secret, peer, pro, pl, now, channel_events(h));
		started++;
	}
	if (!started) {
		h->dialing = false;
	}
	return started > 0;
}

/* ---- the HELLO ---- */

static bool own_hello(const coop_host* h, coop_hello* out) {
	if (!h->haveGame) {
		return false;
	}
	memset(out, 0, sizeof *out);
	out->protocol = COOP_PROTOCOL;
	snprintf(out->appVersion, sizeof out->appVersion, "%s", h->appVersion);
	memcpy(out->romSha1, h->rom, 20);
	out->save = h->save;
	out->female = h->female;
	coop_host_ticket(h, out->ticket, sizeof out->ticket);
	return true;
}

static void send_hello(coop_host* h, const uint8_t peer[32]) {
	coop_hello hello;
	if (!own_hello(h, &hello)) {
		return;
	}
	uint8_t buf[2200];
	size_t n = coop_hello_encode(&hello, buf);
	send_to(h, peer, COOP_MSG_HELLO, buf, n);
}

/* ---- pairing (CoopPairing) ---- */

static bool pairing_active(const coop_host* h) {
	return h->pairOpened && h->step != COOP_PAIR_PAIRED && h->step != COOP_PAIR_FAILED;
}

static void pair_fail(coop_host* h, int reason) {
	h->step = COOP_PAIR_FAILED;
	h->fail = reason;
}

static int fail_for(int code) {
	switch (code) {
	case COOP_TIMEOUT:
	case COOP_PENDING_EXPIRED:
		return COOP_FAIL_TIMEOUT;
	case COOP_DENIED:
		return COOP_FAIL_DENIED;
	case COOP_VERSION:
		return COOP_FAIL_VERSION;
	default:
		return COOP_FAIL_NETWORK;
	}
}

static int candidate_of(coop_host* h, const uint8_t peer[32]) {
	for (int i = 0; i < 4; i++) {
		if (h->candidates[i].used && key_eq(h->candidates[i].peer, peer)) {
			return i;
		}
	}
	return -1;
}

static void drop_candidate(coop_host* h, int i) {
	disconnect_peer(h, h->candidates[i].peer, COOP_CLOSED);
	h->candidates[i].used = false;
}

static void pairing_reset(coop_host* h) {
	h->pairOpened = h->joining = h->iAccepted = h->theyAccepted = h->havePeer = h->haveTheirHello = false;
	memset(h->candidates, 0, sizeof h->candidates);
	h->step = COOP_PAIR_IDLE;
	h->fail = COOP_FAIL_NONE;
}

static void allowed_all_pairs(coop_host* h, bool open) {
	uint8_t list[MAX_PAIRS][32];
	for (int i = 0; i < h->npairs; i++) {
		memcpy(list[i], h->pairs[i].partner, 32);
	}
	set_policy(h, (const uint8_t (*)[32]) list, h->npairs, open);
}

void coop_pair_open(coop_host* h, int64_t now) {
	(void) now;
	if (h->havePeer && h->step != COOP_PAIR_PAIRED) {
		disconnect_peer(h, h->peer, COOP_CLOSED);
	}
	pairing_reset(h);
	if (!h->haveGame) {
		pair_fail(h, COOP_FAIL_NO_GAME);
		return;
	}
	if (pair_for_save(h, &h->save) >= 0) {
		pair_fail(h, COOP_FAIL_SAVE_ALREADY_PAIRED);
		return;
	}
	h->pairOpened = true;
	allowed_all_pairs(h, true);
	h->step = COOP_PAIR_INVITING;
}

static bool pair_dial(coop_host* h, const coop_ticket* t, int64_t now) {
	if (!h->pairOpened || !h->haveGame) {
		pair_fail(h, COOP_FAIL_NETWORK);
		return false;
	}
	if (key_eq(t->peer, h->pub)) {
		pair_fail(h, COOP_FAIL_BAD_INVITE);
		return false;
	}
	h->joining = true;
	if (!dial(h, t->peer, t, now)) {
		pair_fail(h, COOP_FAIL_NETWORK);
		return false;
	}
	h->step = COOP_PAIR_CONNECTING;
	return true;
}

bool coop_pair_join_lan(coop_host* h, const char* keyHex, int64_t now) {
	coop_ticket t;
	memset(&t, 0, sizeof t);
	if (!coop_peer_parse(keyHex, t.peer)) {
		pair_fail(h, COOP_FAIL_BAD_INVITE);
		return false;
	}
	return pair_dial(h, &t, now);
}

bool coop_pair_join_ticket(coop_host* h, const char* text, int64_t now) {
	coop_ticket t;
	if (!coop_ticket_decode(text, &t)) {
		pair_fail(h, COOP_FAIL_BAD_INVITE);
		return false;
	}
	return pair_dial(h, &t, now);
}

static void pair_finish(coop_host* h) {
	if (!h->haveTheirHello || !h->havePeer) {
		return;
	}
	if (pair_for_save(h, &h->save) >= 0 || h->npairs >= MAX_PAIRS) {
		disconnect_peer(h, h->peer, COOP_CLOSED);
		pair_fail(h, COOP_FAIL_SAVE_ALREADY_PAIRED);
		return;
	}
	pair_t* p = &h->pairs[h->npairs++];
	memset(p, 0, sizeof *p);
	p->own = h->save;
	p->partnerSave = h->theirHello.save;
	memcpy(p->partner, h->peer, 32);
	p->female = h->theirHello.female;
	set_ticket(p->ticket, h->theirHello.ticket);
	p->pairedAt = (long long) sNow;
	pairs_save(h);
	accept_peer(h, h->peer);
	h->step = COOP_PAIR_PAIRED;
}

void coop_pair_accept(coop_host* h, int64_t now) {
	sNow = now;
	if (h->step != COOP_PAIR_CONFIRM || !h->havePeer) {
		return;
	}
	h->iAccepted = true;
	send_to(h, h->peer, COOP_MSG_PAIR_ACCEPT, NULL, 0);
	h->step = COOP_PAIR_WAITING;
	if (h->theyAccepted) {
		pair_finish(h);
	}
}

void coop_pair_deny(coop_host* h, int64_t now) {
	sNow = now;
	if (!h->havePeer || (h->step != COOP_PAIR_CONFIRM && h->step != COOP_PAIR_WAITING)) {
		return;
	}
	send_to(h, h->peer, COOP_MSG_PAIR_DENY, NULL, 0);
	disconnect_peer(h, h->peer, COOP_DENIED);
	pair_fail(h, COOP_FAIL_DENIED);
}

void coop_pair_close(coop_host* h) {
	allowed_all_pairs(h, false);
	if (h->havePeer && h->step != COOP_PAIR_PAIRED) {
		disconnect_peer(h, h->peer, COOP_CLOSED);
	}
	for (int i = 0; i < 4; i++) {
		if (h->candidates[i].used) {
			drop_candidate(h, i);
		}
	}
	h->pairOpened = false;
	h->havePeer = false;
	if (h->step != COOP_PAIR_PAIRED && h->step != COOP_PAIR_FAILED) {
		h->step = COOP_PAIR_IDLE;
	}
}

int coop_pair_step(const coop_host* h) { return h->step; }
int coop_pair_fail(const coop_host* h) { return h->fail; }

void coop_pair_partner(const coop_host* h, char* name, size_t nameSize, int* trainerId) {
	if (!h->haveTheirHello) {
		if (nameSize) name[0] = 0;
		*trainerId = 0;
		return;
	}
	name_utf8(h->theirHello.save.name, name, nameSize);
	*trainerId = h->theirHello.save.trainerId;
}

static bool lan_label(const lan_t* l, char* label, size_t size) {
	uint8_t name[8];
	int tid;
	if (!coop_lan_parse(l->userData, name, &tid)) {
		return false;
	}
	name_utf8(name, label, size);
	return true;
}

int coop_pair_nearby_count(const coop_host* h) {
	int n = 0;
	char label[64];
	for (int i = 0; i < h->nlan; i++) {
		if (lan_label(&h->lan[i], label, sizeof label)) n++;
	}
	return n;
}

void coop_pair_nearby(const coop_host* h, int index, char keyHex[65], char* label, size_t labelSize) {
	int n = 0;
	for (int i = 0; i < h->nlan; i++) {
		if (!lan_label(&h->lan[i], label, labelSize)) {
			continue;
		}
		if (n++ == index) {
			coop_peer_hex(h->lan[i].peer, keyHex);
			return;
		}
	}
	keyHex[0] = 0;
	if (labelSize) label[0] = 0;
}

static void pairing_hello(coop_host* h, const uint8_t from[32], const uint8_t* payload, size_t n) {
	coop_hello hello;
	if (!coop_hello_decode(payload, n, &hello)) {
		return;
	}
	int ci = candidate_of(h, from);
	if (hello.protocol != COOP_PROTOCOL) {
		uint8_t code = COOP_VERSION;
		send_to(h, from, COOP_MSG_BYE, &code, 1);
		if (h->joining) {
			disconnect_peer(h, from, COOP_CLOSED);
			pair_fail(h, COOP_FAIL_VERSION);
		} else if (ci >= 0) {
			drop_candidate(h, ci);
		}
		return;
	}
	if (!coop_rom_accepted(hello.romSha1) || memcmp(hello.romSha1, h->rom, 20)) {
		if (h->joining) {
			disconnect_peer(h, from, COOP_CLOSED);
			pair_fail(h, COOP_FAIL_DIFFERENT_ROM);
		} else if (ci >= 0) {
			drop_candidate(h, ci);
		}
		return;
	}
	if (coop_save_equal(&hello.save, &h->save)) {
		if (h->joining) {
			disconnect_peer(h, from, COOP_CLOSED);
		} else {
			if (ci >= 0 && h->candidates[ci].pending) accept_peer(h, from);
			send_hello(h, from);
		}
		pair_fail(h, COOP_FAIL_SAME_SAVE);
		return;
	}
	h->theirHello = hello;
	h->haveTheirHello = true;
	memcpy(h->peer, from, 32);
	h->havePeer = true;
	bool pending = ci >= 0 && h->candidates[ci].pending;
	if (ci >= 0) h->candidates[ci].used = false;
	for (int i = 0; i < 4; i++) {
		if (h->candidates[i].used) drop_candidate(h, i);
	}
	h->confirmDeadline = sNow + CONFIRM_TIMEOUT_MS;
	if (pending) {
		accept_peer(h, from);
		send_hello(h, from);
	}
	h->step = COOP_PAIR_CONFIRM;
}

static void pairing_connected(coop_host* h, const uint8_t peer[32], bool pending, int64_t now) {
	if (!h->joining && !pending && in_list(h->allowed, h->nallowed, peer)) {
		return; // a paired device reconnecting is no joiner
	}
	if (h->haveTheirHello && !key_eq(peer, h->peer)) {
		disconnect_peer(h, peer, COOP_CLOSED);
		return;
	}
	if (h->joining) {
		if (h->havePeer && !key_eq(h->peer, peer)) {
			disconnect_peer(h, peer, COOP_CLOSED);
			return;
		}
		memcpy(h->peer, peer, 32);
		h->havePeer = true;
	}
	if (!h->haveTheirHello) {
		int slot = candidate_of(h, peer);
		for (int i = 0; slot < 0 && i < 4; i++) {
			if (!h->candidates[i].used) slot = i;
		}
		if (slot < 0) {
			disconnect_peer(h, peer, COOP_CLOSED);
			return;
		}
		h->candidates[slot].used = true;
		h->candidates[slot].pending = pending;
		memcpy(h->candidates[slot].peer, peer, 32);
		h->candidates[slot].deadline = now + HELLO_TIMEOUT_MS;
	}
	if (!pending) {
		send_hello(h, peer);
	}
}

static void pairing_frame(coop_host* h, const uint8_t from[32], const uint8_t* b, size_t n) {
	const uint8_t* payload;
	size_t len;
	int type = coop_message_decode(b, n, &payload, &len);
	if (!type) {
		return;
	}
	if (type == COOP_MSG_HELLO) {
		if (!h->haveTheirHello && candidate_of(h, from) >= 0) {
			pairing_hello(h, from, payload, len);
		}
		return;
	}
	if (!h->haveTheirHello || !key_eq(from, h->peer)) {
		return;
	}
	if (type == COOP_MSG_PAIR_ACCEPT) {
		h->theyAccepted = true;
		if (h->iAccepted) pair_finish(h);
	} else if (type == COOP_MSG_PAIR_DENY) {
		disconnect_peer(h, from, COOP_CLOSED);
		pair_fail(h, COOP_FAIL_DENIED);
	}
}

static void pairing_tick(coop_host* h, int64_t now) {
	if (!pairing_active(h)) {
		return;
	}
	if (h->step == COOP_PAIR_CONFIRM || h->step == COOP_PAIR_WAITING) {
		if (now >= h->confirmDeadline) {
			if (h->havePeer) disconnect_peer(h, h->peer, COOP_TIMEOUT);
			pair_fail(h, COOP_FAIL_TIMEOUT);
		}
		return;
	}
	for (int i = 0; i < 4; i++) {
		if (!h->candidates[i].used || now < h->candidates[i].deadline) {
			continue;
		}
		if (h->joining) {
			if (h->havePeer) disconnect_peer(h, h->peer, COOP_TIMEOUT);
			pair_fail(h, COOP_FAIL_TIMEOUT);
			return;
		}
		drop_candidate(h, i);
	}
}

/* ---- the link (CoopLinkImpl) ---- */

static int64_t backoff_next(coop_host* h) {
	int64_t b = h->backoff ? h->backoff : BACKOFF_START_MS;
	h->backoff = b * 2 > BACKOFF_MAX_MS ? BACKOFF_MAX_MS : b * 2;
	uint32_t r;
	coop_random(&r, sizeof r);
	int64_t jitter = (int64_t) (r % 401) - 200; // +-20 %
	return b + b * jitter / 1000;
}

static void link_connected(coop_host* h, const uint8_t peer[32], int64_t now);

static void link_dial(coop_host* h, int64_t now) {
	if (h->linkPair < 0 || h->dialing) {
		return;
	}
	pair_t* p = &h->pairs[h->linkPair];
	if (registered(h, p->partner)) {
		return;
	}
	coop_ticket t, *tp = NULL;
	if (p->ticket[0] && coop_ticket_decode(p->ticket, &t) && key_eq(t.peer, p->partner)) {
		tp = &t;
	}
	if (!dial(h, p->partner, tp, now)) {
		// Nowhere to dial yet (no address known): wait for the partner to dial in or to show up on the LAN.
		h->retryAt = now + backoff_next(h);
	}
}

void coop_link_start(coop_host* h, int64_t now) {
	sNow = now;
	coop_link_stop(h);
	int p = h->haveGame ? pair_for_save(h, &h->save) : -1;
	h->linkPair = p;
	if (p < 0) {
		h->linkState = COOP_LINK_OFF;
		return;
	}
	h->backoff = 0;
	uint8_t list[1][32];
	memcpy(list[0], h->pairs[p].partner, 32);
	set_policy(h, (const uint8_t (*)[32]) list, 1, false);
	h->linkState = COOP_LINK_CONNECTING;
	conn_t* c = registered(h, h->pairs[p].partner);
	if (c) {
		// Still connected from the pairing (or a game before): the HELLOs again on it.
		c->pending = false;
		link_connected(h, h->pairs[p].partner, now);
	} else {
		link_dial(h, now);
	}
}

void coop_link_stop(coop_host* h) {
	if (h->linkPair >= 0 && h->linkPair < h->npairs) {
		const uint8_t* partner = h->pairs[h->linkPair].partner;
		if (h->helloOk) {
			send_to(h, partner, COOP_MSG_BYE, NULL, 0);
		}
		disconnect_peer(h, partner, COOP_CLOSED);
	}
	h->linkPair = -1;
	h->live = h->helloOk = false;
	h->linkState = COOP_LINK_OFF;
	set_policy(h, NULL, 0, false);
}

int coop_link_state(const coop_host* h) { return h->linkState; }

void coop_link_partner(const coop_host* h, char* name, size_t size) {
	if (h->linkPair < 0) {
		if (size) name[0] = 0;
		return;
	}
	name_utf8(h->pairs[h->linkPair].partnerSave.name, name, size);
}

bool coop_link_send_presence(coop_host* h, const uint8_t* bytes, size_t n) {
	if (h->linkState != COOP_LINK_CONNECTED || h->linkPair < 0) {
		return false;
	}
	return send_to(h, h->pairs[h->linkPair].partner, COOP_PRESENCE_TYPE, bytes, n);
}

static void link_drop(coop_host* h, int64_t now) {
	h->live = h->helloOk = false;
	h->linkState = COOP_LINK_DISCONNECTED;
	h->retryAt = now + backoff_next(h);
}

static void link_connected(coop_host* h, const uint8_t peer[32], int64_t now) {
	pair_t* p = &h->pairs[h->linkPair];
	if (!key_eq(peer, p->partner)) {
		disconnect_peer(h, peer, COOP_NOT_ALLOWED);
		return;
	}
	h->live = true;
	h->helloOk = false;
	h->helloDeadline = now + HELLO_TIMEOUT_MS;
	send_hello(h, peer);
}

static void link_frame(coop_host* h, const uint8_t from[32], const uint8_t* b, size_t n, int64_t now) {
	pair_t* p = &h->pairs[h->linkPair];
	if (!key_eq(from, p->partner)) {
		return;
	}
	const uint8_t* payload;
	size_t len;
	int type = coop_message_decode(b, n, &payload, &len);
	if (type == COOP_MSG_HELLO) {
		coop_hello hello;
		if (!coop_hello_decode(payload, len, &hello)) {
			return;
		}
		if (hello.protocol != COOP_PROTOCOL || !coop_rom_accepted(hello.romSha1) || memcmp(hello.romSha1, h->rom, 20) ||
		    !coop_save_equal(&hello.save, &p->partnerSave)) {
			disconnect_peer(h, from, COOP_CLOSED);
			link_drop(h, now);
			return;
		}
		h->helloOk = true;
		h->linkState = COOP_LINK_CONNECTED;
		h->backoff = 0;
		if (hello.ticket[0] && strcmp(hello.ticket, p->ticket)) {
			set_ticket(p->ticket, hello.ticket);
			pairs_save(h);
		}
	} else if (type == COOP_MSG_BYE) {
		disconnect_peer(h, from, COOP_CLOSED);
		link_drop(h, now);
	} else if (type >= COOP_FIRST_APP_TYPE && h->helloOk) {
		if (type == COOP_PRESENCE_TYPE && h->io.presence) {
			h->io.presence(h->io.ctx, payload, len);
		}
	}
}

static void link_tick(coop_host* h, int64_t now) {
	if (h->linkPair < 0 || h->linkState == COOP_LINK_OFF) {
		return;
	}
	if (h->live && !h->helloOk && now >= h->helloDeadline) {
		disconnect_peer(h, h->pairs[h->linkPair].partner, COOP_TIMEOUT);
		link_drop(h, now);
		return;
	}
	if (!h->live && !h->dialing && now >= h->retryAt) {
		h->linkState = h->linkState == COOP_LINK_CONNECTED ? COOP_LINK_DISCONNECTED : h->linkState;
		link_dial(h, now);
	}
}

/* ---- dispatch ---- */

static void on_connected(coop_host* h, const uint8_t peer[32], bool pending, int64_t now) {
	if (pairing_active(h)) {
		pairing_connected(h, peer, pending, now);
	} else if (h->linkPair >= 0) {
		link_connected(h, peer, now);
	} else {
		disconnect_peer(h, peer, COOP_NOT_ALLOWED);
	}
}

static void on_frame(coop_host* h, const uint8_t peer[32], const uint8_t* b, size_t n, int64_t now) {
	if (pairing_active(h)) {
		if ((h->havePeer && key_eq(peer, h->peer)) || candidate_of(h, peer) >= 0) {
			pairing_frame(h, peer, b, n);
		}
	} else if (h->linkPair >= 0) {
		link_frame(h, peer, b, n, now);
	}
}

static void on_disconnected(coop_host* h, const uint8_t peer[32], int code, int64_t now) {
	if (code == COOP_DUPLICATE) {
		return;
	}
	if (pairing_active(h)) {
		int ci = candidate_of(h, peer);
		if (ci >= 0) h->candidates[ci].used = false;
		if (!h->havePeer || !key_eq(peer, h->peer)) {
			return;
		}
		if (h->step == COOP_PAIR_CONFIRM || h->step == COOP_PAIR_WAITING || (h->joining && ci >= 0)) {
			pair_fail(h, fail_for(code));
		}
	} else if (h->linkPair >= 0 && key_eq(peer, h->pairs[h->linkPair].partner)) {
		link_drop(h, now);
	}
}

static void on_dial_failed(coop_host* h, int code, int64_t now) {
	if (pairing_active(h)) {
		if (h->joining && h->step == COOP_PAIR_CONNECTING) {
			pair_fail(h, fail_for(code));
		}
	} else if (h->linkPair >= 0 && !h->live) {
		link_drop(h, now);
	}
}

/* ---- the host ---- */

coop_host* coop_host_new(const uint8_t secret[32], const char* pairsPath, const char* appVersion, coop_io io) {
	coop_host* h = calloc(1, sizeof *h);
	if (!h) {
		return NULL;
	}
	memcpy(h->secret, secret, 32);
	coop_x25519_public(secret, h->pub);
	h->io = io;
	snprintf(h->pairsPath, sizeof h->pairsPath, "%s", pairsPath ? pairsPath : "");
	snprintf(h->appVersion, sizeof h->appVersion, "%s", appVersion && *appVersion ? appVersion : "capsule");
	h->linkPair = -1;
	pairs_load(h);
	return h;
}

void coop_host_free(coop_host* h) {
	if (!h) {
		return;
	}
	coop_link_stop(h);
	for (int i = 0; i < MAX_CONNS; i++) {
		if (h->conns[i].used) {
			coop_channel_close(&h->conns[i].ch, COOP_CLOSED);
			free_conn(h, &h->conns[i], true);
		}
	}
	coop_wipe(h->secret, 32);
	free(h);
}

void coop_host_peer_hex(const coop_host* h, char out[65]) { coop_peer_hex(h->pub, out); }

void coop_host_lan_name(const coop_host* h, char out[18]) {
	char hex[65];
	coop_peer_hex(h->pub, hex);
	snprintf(out, 18, "pdco-%.12s", hex);
}

void coop_host_lan_user_data(const coop_host* h, char* out, size_t size) {
	if (h->pairOpened && h->haveGame && h->step == COOP_PAIR_INVITING) {
		coop_lan_user_data(&h->save, out, size);
	} else if (size) {
		out[0] = 0;
	}
}

void coop_host_set_addresses(coop_host* h, const coop_address* a, int count) {
	h->naddr = count < 0 ? 0 : count > 4 ? 4 : count;
	memcpy(h->addrs, a, sizeof *a * (size_t) h->naddr);
}

void coop_host_ticket(const coop_host* h, char* out, size_t size) {
	coop_ticket t;
	memset(&t, 0, sizeof t);
	memcpy(t.peer, h->pub, 32);
	t.count = h->naddr;
	memcpy(t.addresses, h->addrs, sizeof h->addrs);
	coop_ticket_encode(&t, out, size);
}

bool coop_host_set_game_id(coop_host* h, const uint8_t romSha1[20], const coop_save_id* save, bool female) {
	h->haveGame = false;
	if (!coop_rom_accepted(romSha1) || save->name[0] == 0xFF || save->name[0] == 0) {
		return false;
	}
	memcpy(h->rom, romSha1, 20);
	h->save = *save;
	h->female = female;
	h->haveGame = true;
	return true;
}

bool coop_host_set_game(coop_host* h, const uint8_t romSha1[20], const uint8_t* save, size_t len) {
	h->haveGame = false;
	if (!coop_rom_accepted(romSha1) || !save) {
		return false;
	}
	int err = 0;
	PKSave* s = pk_save_open(save, len, &err);
	if (!s) {
		return false;
	}
	uint8_t name[8];
	bool female;
	pk_save_trainer_raw(s, name, &female);
	uint32_t id = pk_save_trainer_id(s);
	pk_save_free(s);
	if (name[0] == 0xFF || name[0] == 0) {
		return false;
	}
	memcpy(h->rom, romSha1, 20);
	memcpy(h->save.name, name, 8);
	h->save.trainerId = (uint16_t) (id & 0xFFFF);
	h->save.secretId = (uint16_t) (id >> 16);
	h->female = female;
	h->haveGame = true;
	return true;
}

void coop_host_lan_seen(coop_host* h, const char* keyHex, const char* userData, const coop_address* address) {
	uint8_t peer[32];
	if (!coop_peer_parse(keyHex, peer) || key_eq(peer, h->pub)) {
		return;
	}
	lan_t* l = NULL;
	for (int i = 0; i < h->nlan; i++) {
		if (key_eq(h->lan[i].peer, peer)) l = &h->lan[i];
	}
	if (!l) {
		if (h->nlan == MAX_LAN) return;
		l = &h->lan[h->nlan++];
		memset(l, 0, sizeof *l);
		memcpy(l->peer, peer, 32);
	}
	snprintf(l->userData, sizeof l->userData, "%s", userData ? userData : "");
	if (address) {
		l->addr = *address;
		l->hasAddr = true;
	}
	// The partner just showed up: dial now rather than at the next retry.
	if (h->linkPair >= 0 && !h->live && key_eq(peer, h->pairs[h->linkPair].partner)) {
		h->retryAt = 0;
	}
}

void coop_host_lan_lost(coop_host* h, const char* keyHex) {
	uint8_t peer[32];
	if (!coop_peer_parse(keyHex, peer)) {
		return;
	}
	for (int i = 0; i < h->nlan; i++) {
		if (key_eq(h->lan[i].peer, peer)) {
			h->lan[i] = h->lan[--h->nlan];
			return;
		}
	}
}

void coop_host_tick(coop_host* h, int64_t now) {
	sNow = now;
	for (int i = 0; i < MAX_CONNS; i++) {
		conn_t* c = &h->conns[i];
		if (!c->used) continue;
		if (c->registered && c->pending && now - c->pendingSince >= PENDING_MS) {
			uint8_t peer[32];
			memcpy(peer, c->ch.remote, 32);
			coop_channel_close(&c->ch, COOP_PENDING_EXPIRED);
			free_conn(h, c, true);
			on_disconnected(h, peer, COOP_PENDING_EXPIRED, now);
			continue;
		}
		if (c->tcpUp) {
			coop_channel_tick(&c->ch, now); // may free c through ch_closed
		} else if (c->outgoing && now - c->ch.startedAt >= 10000) {
			conn_ended(h, c, COOP_TIMEOUT, true); // a dial that never connected
		}
	}
	pairing_tick(h, now);
	link_tick(h, now);
}

/* ---- the pairs kept ---- */

int coop_pairs_count(const coop_host* h) { return h->npairs; }

void coop_pairs_get(const coop_host* h, int i, char* name, size_t size, bool* current) {
	if (i < 0 || i >= h->npairs) {
		if (size) name[0] = 0;
		*current = false;
		return;
	}
	name_utf8(h->pairs[i].partnerSave.name, name, size);
	*current = h->haveGame && coop_save_equal(&h->pairs[i].own, &h->save);
}

void coop_pairs_remove(coop_host* h, int i) {
	if (i < 0 || i >= h->npairs) {
		return;
	}
	if (h->linkPair == i) {
		coop_link_stop(h);
	} else if (h->linkPair > i) {
		h->linkPair--;
	}
	memmove(&h->pairs[i], &h->pairs[i + 1], sizeof h->pairs[0] * (size_t) (h->npairs - i - 1));
	h->npairs--;
	pairs_save(h);
}

bool coop_pairs_has_current(const coop_host* h) { return h->haveGame && pair_for_save(h, &h->save) >= 0; }
