/* Two co-op hosts over an in-memory network: pairing by ticket (both accept), then the link while playing (each dials,
 * the HELLOs check, presence goes both ways), a drop and the redial, and the refusals (another ROM, a stranger). */
#include "coop_crypto.h"
#include "coop_host.h"
#include "coop_noise.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

/* The network: connection ids are global; each has two ends (a host and its peer id), bytes queued per end. */
#define NC 400
static struct {
	bool used, up;
	int host, otherHost; /* which host owns this end */
	int other;           /* the other end's id */
	uint8_t q[1 << 16];
	size_t qn;
} net[NC];
static coop_host* hosts[3];
static coop_address hostAddr[3];
static bool hostListening[3] = {true, true, true};
static int64_t now;
static uint8_t presenceGot[3][20];
static int presenceCount[3];

static int nextEnd = 1; /* ids are never reused */
static int new_end(int host) {
	if (nextEnd >= NC) return -1;
	int i = nextEnd++;
	memset(&net[i], 0, sizeof net[i]);
	net[i].used = true;
	net[i].host = host;
	return i;
}

static bool io_write(void* ctx, int conn, const uint8_t* b, size_t n) {
	(void) ctx;
	if (conn <= 0 || conn >= NC || !net[conn].used || !net[conn].up) return false;
	int o = net[conn].other;
	if (!net[o].used || net[o].qn + n > sizeof net[o].q) return false;
	memcpy(net[o].q + net[o].qn, b, n);
	net[o].qn += n;
	return true;
}

static void io_close(void* ctx, int conn) {
	(void) ctx;
	if (conn <= 0 || conn >= NC || !net[conn].used) return;
	int o = net[conn].other;
	net[conn].used = false;
	if (o && net[o].used) net[o].up = false; /* the other side sees it gone at the next pump */
}

static int dialing_host;
static int io_dial(void* ctx, const coop_address* a) {
	(void) ctx;
	int target = -1;
	for (int i = 0; i < 3; i++) {
		if (hosts[i] && hostListening[i] && !memcmp(&hostAddr[i], a, sizeof *a)) target = i;
	}
	int mine = new_end(dialing_host);
	if (target < 0) {
		net[mine].other = 0;
		return mine; /* fails at the next pump */
	}
	int theirs = new_end(target);
	net[mine].other = theirs;
	net[theirs].other = mine;
	net[mine].up = net[theirs].up = true;
	coop_host_accepted(hosts[target], theirs, now);
	return mine;
}

static void io_presence(void* ctx, const uint8_t* b, size_t n) {
	int who = (int) (intptr_t) ctx;
	if (n == 20) memcpy(presenceGot[who], b, 20);
	presenceCount[who]++;
}

static bool dialedReported[NC];

static void pump(int rounds) {
	for (int r = 0; r < rounds; r++) {
		now += 20;
		for (int i = 1; i < NC; i++) {
			if (!net[i].used) continue;
			coop_host* h = hosts[net[i].host];
			if (!dialedReported[i] && net[i].other == 0) { /* a dial to nowhere */
				dialedReported[i] = true;
				net[i].used = false;
				coop_host_dialed(h, i, false, now);
				continue;
			}
			if (!dialedReported[i] && net[i].up) {
				dialedReported[i] = true;
				/* accepted ends were reported at once; dialed ones now */
				bool isDialer = false;
				for (int k = 0; k < 3; k++) (void) k;
				(void) isDialer;
			}
			if (net[i].qn) {
				uint8_t buf[1 << 16];
				size_t n = net[i].qn;
				memcpy(buf, net[i].q, n);
				net[i].qn = 0;
				coop_host_data(h, i, buf, n, now);
			}
			if (net[i].used && !net[i].up) {
				net[i].used = false;
				coop_host_gone(h, i, now);
			}
		}
		for (int k = 0; k < 3; k++) if (hosts[k]) coop_host_tick(hosts[k], now);
	}
}

/* Wraps dial so the dialer is told its connection is up on the next step. */
static int pendingDialed[NC], npd;
static int io_dial_for(void* ctx, const coop_address* a) {
	dialing_host = (int) (intptr_t) ctx;
	int id = io_dial(ctx, a);
	if (id > 0 && net[id].other) pendingDialed[npd++] = id;
	dialedReported[id] = net[id].other != 0;
	return id;
}

static void flush_dials(void) {
	for (int i = 0; i < npd; i++) {
		int id = pendingDialed[i];
		if (net[id].used) coop_host_dialed(hosts[net[id].host], id, true, now);
	}
	npd = 0;
}

static void run(int rounds) {
	for (int r = 0; r < rounds; r++) {
		flush_dials();
		pump(1);
	}
}

static coop_host* make(int i, const char* path) {
	uint8_t secret[32];
	coop_random(secret, 32);
	coop_io io = {(void*) (intptr_t) i, io_write, io_close, io_dial_for, io_presence};
	remove(path);
	coop_host* h = coop_host_new(secret, path, "test-1.0", io);
	hostAddr[i].family = 4;
	hostAddr[i].addr[0] = 10;
	hostAddr[i].addr[3] = (uint8_t) (i + 1);
	hostAddr[i].port = 4000;
	coop_host_set_addresses(h, &hostAddr[i], 1);
	return h;
}

static const uint8_t FR_EMERALD[20] = {0xca, 0x66, 0x66, 0x51, 0x37, 0x4d, 0x89, 0xca, 0x43, 0x90,
                                       0x07, 0xbe, 0xd5, 0x4d, 0x83, 0x9e, 0xb7, 0xbd, 0x14, 0xd0};
static const uint8_t EN_EMERALD[20] = {0xf3, 0xae, 0x08, 0x81, 0x81, 0xbf, 0x58, 0x3e, 0x55, 0xda,
                                       0xf9, 0x62, 0xa9, 0x2b, 0xb4, 0x6f, 0x4f, 0x1d, 0x07, 0xb7};

int main(void) {
	hosts[0] = make(0, "/tmp/coop_pairs_a.txt");
	hosts[1] = make(1, "/tmp/coop_pairs_b.txt");
	coop_save_id sa = {1234, 4321, {0xBB, 0xCC, 0xDD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}};
	coop_save_id sb = {777, 888, {0xC5, 0xC6, 0xC7, 0xC8, 0xFF, 0xFF, 0xFF, 0xFF}};
	CHECK(coop_host_set_game_id(hosts[0], FR_EMERALD, &sa, false));
	CHECK(coop_host_set_game_id(hosts[1], FR_EMERALD, &sb, true));

	/* ---- pairing: A opens, B joins A's ticket ---- */
	coop_pair_open(hosts[0], now);
	coop_pair_open(hosts[1], now);
	CHECK(coop_pair_step(hosts[0]) == COOP_PAIR_INVITING);
	char ua[256];
	coop_host_lan_user_data(hosts[0], ua, sizeof ua);
	CHECK(!strncmp(ua, "pokedaisy-coop/1;bbccdd", 23));
	char ticket[300];
	coop_host_ticket(hosts[0], ticket, sizeof ticket);
	CHECK(!strncmp(ticket, "pdco", 4));
	CHECK(coop_pair_join_ticket(hosts[1], ticket, now));
	run(20);
	CHECK(coop_pair_step(hosts[0]) == COOP_PAIR_CONFIRM);
	CHECK(coop_pair_step(hosts[1]) == COOP_PAIR_CONFIRM);
	char name[64];
	int tid;
	coop_pair_partner(hosts[0], name, sizeof name, &tid);
	CHECK(tid == 777);
	coop_pair_accept(hosts[0], now);
	run(5);
	CHECK(coop_pair_step(hosts[0]) == COOP_PAIR_WAITING);
	coop_pair_accept(hosts[1], now);
	run(10);
	CHECK(coop_pair_step(hosts[0]) == COOP_PAIR_PAIRED);
	CHECK(coop_pair_step(hosts[1]) == COOP_PAIR_PAIRED);
	CHECK(coop_pairs_count(hosts[0]) == 1 && coop_pairs_count(hosts[1]) == 1);
	coop_pair_close(hosts[0]);
	coop_pair_close(hosts[1]);
	run(10);

	/* The pairs file is read back by a new host. */
	{
		uint8_t k[32] = {1};
		coop_io none = {0};
		coop_host* again = coop_host_new(k, "/tmp/coop_pairs_b.txt", "test-1.0", none);
		CHECK(coop_pairs_count(again) == 1);
		coop_host_free(again);
	}

	/* ---- pairing the other way round (B opens, A joins), after A forgot its pair ---- */
	coop_host_free(hosts[1]);
	hosts[1] = make(1, "/tmp/coop_pairs_b2.txt");
	CHECK(coop_host_set_game_id(hosts[1], FR_EMERALD, &sb, true));
	coop_pairs_remove(hosts[0], 0);
	coop_pair_open(hosts[0], now);
	coop_pair_open(hosts[1], now);
	coop_host_ticket(hosts[1], ticket, sizeof ticket);
	CHECK(coop_pair_join_ticket(hosts[0], ticket, now)); /* the other way round this time */
	run(20);
	coop_pair_accept(hosts[0], now);
	coop_pair_accept(hosts[1], now);
	run(10);
	CHECK(coop_pair_step(hosts[0]) == COOP_PAIR_PAIRED && coop_pair_step(hosts[1]) == COOP_PAIR_PAIRED);
	coop_pair_close(hosts[0]);
	coop_pair_close(hosts[1]);
	run(5);

	coop_link_start(hosts[0], now);
	coop_link_start(hosts[1], now);
	run(40);
	CHECK(coop_link_state(hosts[0]) == COOP_LINK_CONNECTED);
	CHECK(coop_link_state(hosts[1]) == COOP_LINK_CONNECTED);
	uint8_t upd[20] = {1, 1, 0, 9, 0x10, 0x01, 0x20, 0x02, 1, 0, 3, 0};
	CHECK(coop_link_send_presence(hosts[0], upd, 20));
	run(3);
	CHECK(presenceCount[1] == 1 && !memcmp(presenceGot[1], upd, 20));
	upd[3] = 10;
	CHECK(coop_link_send_presence(hosts[1], upd, 20));
	run(3);
	CHECK(presenceCount[0] == 1 && presenceGot[0][3] == 10);

	/* A drop: B's connections vanish; both go DISCONNECTED, then come back by themselves. */
	for (int i = 1; i < NC; i++) {
		if (net[i].used && net[i].host == 1) {
			io_close(NULL, i);
			coop_host_gone(hosts[1], i, now); /* the socket's end, seen by its own side too */
		}
	}
	run(5);
	CHECK(coop_link_state(hosts[0]) != COOP_LINK_CONNECTED);
	run(200); /* backoff: about a second */
	CHECK(coop_link_state(hosts[0]) == COOP_LINK_CONNECTED);
	CHECK(coop_link_state(hosts[1]) == COOP_LINK_CONNECTED);

	/* A stranger (not paired) is refused while not pairing. */
	hosts[2] = make(2, "/tmp/coop_pairs_c.txt");
	coop_save_id sc = {5, 6, {0xD0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}};
	CHECK(coop_host_set_game_id(hosts[2], FR_EMERALD, &sc, false));
	coop_pair_open(hosts[2], now);
	coop_host_ticket(hosts[0], ticket, sizeof ticket);
	CHECK(coop_pair_join_ticket(hosts[2], ticket, now));
	run(30);
	CHECK(coop_pair_step(hosts[2]) == COOP_PAIR_FAILED);
	CHECK(coop_link_state(hosts[0]) == COOP_LINK_CONNECTED);

	/* Another ROM: an English Emerald can't pair with a French one. */
	coop_link_stop(hosts[0]);
	coop_link_stop(hosts[1]);
	run(5);
	CHECK(coop_host_set_game_id(hosts[2], EN_EMERALD, &sc, false));
	coop_save_id sd = {9, 9, {0xD5, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}};
	CHECK(coop_host_set_game_id(hosts[1], FR_EMERALD, &sd, false));
	coop_pair_open(hosts[1], now);
	coop_pair_open(hosts[2], now);
	coop_host_ticket(hosts[1], ticket, sizeof ticket);
	CHECK(coop_pair_join_ticket(hosts[2], ticket, now));
	run(30);
	/* The host drops a joiner whose HELLO names another ROM (it never lets it in, so the joiner only sees the drop), and
	 * keeps waiting for the right one. */
	CHECK(coop_pair_step(hosts[2]) == COOP_PAIR_FAILED);
	CHECK(coop_pair_step(hosts[1]) == COOP_PAIR_INVITING);

	for (int i = 0; i < 3; i++) coop_host_free(hosts[i]);
	if (failures) {
		printf("%d failure(s)\n", failures);
		return 1;
	}
	printf("coophost: ok\n");
	return 0;
}
