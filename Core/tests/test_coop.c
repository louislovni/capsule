/* The co-op link in C (Core/coop): the crypto against known answers, Noise IK against the published vector PokeDaisy's
 * own test checks, and two channels talking through a pipe (frames, pings, a refusal, a close). */
#include "coop_crypto.h"
#include "coop_noise.h"
#include "coop_vector.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static size_t unhex(const char* s, uint8_t* out) {
	size_t n = strlen(s) / 2;
	for (size_t i = 0; i < n; i++) {
		unsigned v;
		sscanf(s + 2 * i, "%2x", &v);
		out[i] = (uint8_t) v;
	}
	return n;
}

static void tohex(const uint8_t* p, size_t n, char* out) {
	for (size_t i = 0; i < n; i++) {
		sprintf(out + 2 * i, "%02x", p[i]);
	}
	out[2 * n] = 0;
}

static void crypto(void) {
	uint8_t out[64];
	char hex[200];
	coop_sha256("abc", 3, out);
	tohex(out, 32, hex);
	CHECK(!strcmp(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
	coop_hmac_sha256((const uint8_t*) "key", 3, "The quick brown fox jumps over the lazy dog", 43, NULL, 0, out);
	tohex(out, 32, hex);
	CHECK(!strcmp(hex, "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"));
	// AES-256-GCM, NIST's test case 13 (zero key, zero nonce, empty): the tag alone.
	uint8_t key[32] = {0}, iv[12] = {0};
	coop_aesgcm_encrypt(key, iv, NULL, 0, NULL, 0, out);
	tohex(out, 16, hex);
	CHECK(!strcmp(hex, "530f8afbc74536b9a963b4f1c4cb738b"));
	// Test case 14: one zero block.
	uint8_t zero[16] = {0};
	coop_aesgcm_encrypt(key, iv, NULL, 0, zero, 16, out);
	tohex(out, 32, hex);
	CHECK(!strcmp(hex, "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919"));
	uint8_t back[16];
	CHECK(coop_aesgcm_decrypt(key, iv, NULL, 0, out, 32, back) && !memcmp(back, zero, 16));
	out[0] ^= 1;
	CHECK(!coop_aesgcm_decrypt(key, iv, NULL, 0, out, 32, back));
	// X25519, RFC 7748 section 6.1.
	uint8_t a[32], bpub[32], shared[32];
	unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a", a);
	unhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", bpub);
	CHECK(coop_x25519(a, bpub, shared));
	tohex(shared, 32, hex);
	CHECK(!strcmp(hex, "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"));
	uint8_t low[32] = {0};
	CHECK(!coop_x25519(a, low, shared)); // a low-order key gives zero: refused
}

static void vector(void) {
	uint8_t prologue[64], is[32], ie[32], irs[32], rsec[32], re[32];
	size_t pl = unhex(V_INIT_PROLOGUE, prologue);
	unhex(V_INIT_STATIC, is);
	unhex(V_INIT_EPHEMERAL, ie);
	unhex(V_INIT_REMOTE_STATIC, irs);
	unhex(V_RESP_STATIC, rsec);
	unhex(V_RESP_EPHEMERAL, re);
	coop_noise init, resp;
	coop_noise_init(&init, true, is, irs, prologue, pl, ie);
	coop_noise_init(&resp, false, rsec, NULL, prologue, pl, re);
	uint8_t payload[256], msg[512], got[512], want[512];
	char hex[1024];
	size_t n = unhex(V_MESSAGES[0][0], payload);
	size_t m = coop_noise_write(&init, payload, n, msg);
	tohex(msg, m, hex);
	CHECK(!strcmp(hex, V_MESSAGES[0][1]));
	CHECK(coop_noise_read(&resp, msg, m, got) == (long) n && !memcmp(got, payload, n));
	n = unhex(V_MESSAGES[1][0], payload);
	m = coop_noise_write(&resp, payload, n, msg);
	tohex(msg, m, hex);
	CHECK(!strcmp(hex, V_MESSAGES[1][1]));
	CHECK(coop_noise_read(&init, msg, m, got) == (long) n && !memcmp(got, payload, n));
	CHECK(coop_noise_done(&init) && coop_noise_done(&resp));
	coop_cipher iSend, iRecv, rSend, rRecv;
	coop_noise_split(&init, &iSend, &iRecv);
	coop_noise_split(&resp, &rSend, &rRecv);
	for (size_t i = 2; i < sizeof V_MESSAGES / sizeof V_MESSAGES[0]; i++) {
		bool fromInit = i % 2 == 0;
		n = unhex(V_MESSAGES[i][0], payload);
		coop_cipher_encrypt(fromInit ? &iSend : &rSend, payload, n, msg);
		tohex(msg, n + 16, hex);
		unhex(V_MESSAGES[i][1], want);
		CHECK(!strcmp(hex, V_MESSAGES[i][1]));
		CHECK(coop_cipher_decrypt(fromInit ? &rRecv : &iRecv, msg, n + 16, got) && !memcmp(got, payload, n));
	}
}

/* ---- two channels through an in-memory pipe ---- */

typedef struct {
	uint8_t bytes[4096];
	size_t n;
} queued;

static struct side {
	coop_channel ch;
	queued inbox[64];
	int count;
	bool opened, closed;
	int closeCode;
	char frames[256];
	int refuseWith;
} A, B;

static struct side* other(coop_channel* ch) { return ch == &A.ch ? &B : &A; }
static struct side* self_of(coop_channel* ch) { return ch == &A.ch ? &A : &B; }

static bool t_pipe(void* ctx, coop_channel* ch, const uint8_t* b, size_t n) {
	(void) ctx;
	struct side* o = other(ch);
	if (o->count == 64 || n > sizeof o->inbox[0].bytes) return false;
	memcpy(o->inbox[o->count].bytes, b, n);
	o->inbox[o->count++].n = n;
	return true;
}
static int t_decide(void* ctx, coop_channel* ch, const uint8_t r[32]) { (void) ctx; (void) r; return self_of(ch)->refuseWith; }
static void t_opened(void* ctx, coop_channel* ch, const uint8_t r[32]) { (void) ctx; (void) r; self_of(ch)->opened = true; }
static void t_frame(void* ctx, coop_channel* ch, const uint8_t* b, size_t n) {
	(void) ctx;
	strncat(self_of(ch)->frames, (const char*) b, n);
}
static void t_closed(void* ctx, coop_channel* ch, int code, bool before) {
	(void) ctx;
	(void) before;
	self_of(ch)->closed = true;
	self_of(ch)->closeCode = code;
}

static void deliver(int64_t now) {
	for (int round = 0; round < 8; round++) {
		struct side* s[2] = {&A, &B};
		for (int k = 0; k < 2; k++) {
			queued q[64];
			int c = s[k]->count;
			memcpy(q, s[k]->inbox, sizeof q[0] * (size_t) c);
			s[k]->count = 0;
			for (int i = 0; i < c; i++) coop_channel_receive(&s[k]->ch, q[i].bytes, q[i].n, now);
		}
	}
}

static void channels(int refuse) {
	memset(&A, 0, sizeof A);
	memset(&B, 0, sizeof B);
	B.refuseWith = refuse;
	uint8_t a[32], b[32], bpub[32], pro[64];
	coop_random(a, 32);
	coop_random(b, 32);
	coop_x25519_public(b, bpub);
	size_t pl = coop_prologue(COOP_PATH_TCP, NULL, pro);
	coop_channel_events ev = {NULL, t_pipe, t_decide, t_opened, t_frame, t_closed};
	coop_channel_init(&A.ch, true, a, bpub, pro, pl, 0, ev);
	coop_channel_init(&B.ch, false, b, NULL, pro, pl, 0, ev);
	coop_channel_begin(&A.ch);
	deliver(10);
	if (refuse) {
		CHECK(!A.opened && A.closed && A.closeCode == refuse);
		CHECK(B.closed && B.closeCode == refuse);
		return;
	}
	CHECK(A.opened && B.opened);
	uint8_t apub[32];
	coop_x25519_public(a, apub);
	CHECK(!memcmp(B.ch.remote, apub, 32));
	CHECK(coop_channel_send(&A.ch, (const uint8_t*) "hello ", 6));
	CHECK(coop_channel_send(&B.ch, (const uint8_t*) "there", 5));
	CHECK(coop_channel_send(&A.ch, (const uint8_t*) "again", 5));
	coop_channel_tick(&A.ch, 6000); // a ping
	deliver(6000);
	CHECK(!strcmp(B.frames, "hello again"));
	CHECK(!strcmp(A.frames, "there"));
	CHECK(!A.closed && !B.closed);
	coop_channel_close(&A.ch, COOP_CLOSED);
	deliver(6100);
	CHECK(B.closed && B.closeCode == COOP_CLOSED);
	// A forged message ends the session.
	memset(&A, 0, sizeof A);
	memset(&B, 0, sizeof B);
	coop_channel_init(&A.ch, true, a, bpub, pro, pl, 0, ev);
	coop_channel_init(&B.ch, false, b, NULL, pro, pl, 0, ev);
	coop_channel_begin(&A.ch);
	deliver(10);
	uint8_t junk[40] = {1, 2, 3};
	coop_channel_receive(&B.ch, junk, sizeof junk, 20);
	CHECK(B.closed && B.closeCode == COOP_ERROR);
	// Silence times a session out.
	coop_channel_tick(&A.ch, 10 + COOP_IDLE_MS);
	CHECK(A.closed && A.closeCode == COOP_TIMEOUT);
}

int main(void) {
	crypto();
	vector();
	channels(0);
	channels(COOP_NOT_ALLOWED);
	if (failures) {
		printf("%d failure(s)\n", failures);
		return 1;
	}
	printf("coop: ok\n");
	return 0;
}
