/* PokeDaisy's co-op channel (coop_noise.h): CoopNoise.kt and CoopChannel.kt, byte for byte. Licensed under the GNU GPL v3. */
#include "coop_noise.h"

#include <stdlib.h>
#include <string.h>

#include "coop_crypto.h"

#if defined(_WIN32)
#include <windows.h>
#include <bcrypt.h>
#elif defined(__APPLE__)
#include <stdlib.h>
#else
#include <sys/random.h>
#endif

void coop_random(void* out, size_t n) {
#if defined(_WIN32)
	BCryptGenRandom(NULL, out, (ULONG) n, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
#elif defined(__APPLE__)
	arc4random_buf(out, n);
#else
	uint8_t* p = out;
	while (n) {
		ssize_t got = getrandom(p, n, 0);
		if (got <= 0) {
			abort();
		}
		p += got;
		n -= (size_t) got;
	}
#endif
}

/* ---- the cipher ---- */

static void nonce_of(uint64_t counter, uint8_t iv[12]) {
	memset(iv, 0, 4);
	for (int i = 0; i < 8; i++) {
		iv[4 + i] = (uint8_t) (counter >> (56 - 8 * i));
	}
}

void coop_cipher_encrypt(coop_cipher* c, const uint8_t* in, size_t n, uint8_t* out) {
	uint8_t iv[12];
	nonce_of(c->n++, iv);
	coop_aesgcm_encrypt(c->key, iv, NULL, 0, in, n, out);
}

bool coop_cipher_decrypt(coop_cipher* c, const uint8_t* in, size_t n, uint8_t* out) {
	uint8_t iv[12];
	nonce_of(c->n, iv);
	if (!coop_aesgcm_decrypt(c->key, iv, NULL, 0, in, n, out)) {
		return false;
	}
	c->n++;
	return true;
}

/* ---- Noise IK ---- */

static const char PROTOCOL[] = "Noise_IK_25519_AESGCM_SHA256";

static void mix_hash(coop_noise* n, const uint8_t* data, size_t len) {
	coop_sha256_ctx c;
	coop_sha256_init(&c);
	coop_sha256_update(&c, n->h, 32);
	coop_sha256_update(&c, data, len);
	coop_sha256_final(&c, n->h);
}

static void hkdf2(const uint8_t ck[32], const uint8_t* input, size_t len, uint8_t o1[32], uint8_t o2[32]) {
	uint8_t temp[32], one = 1, two = 2;
	coop_hmac_sha256(ck, 32, input, len, NULL, 0, temp);
	coop_hmac_sha256(temp, 32, &one, 1, NULL, 0, o1);
	coop_hmac_sha256(temp, 32, o1, 32, &two, 1, o2);
	coop_wipe(temp, sizeof temp);
}

static void mix_key(coop_noise* n, const uint8_t input[32]) {
	uint8_t nck[32];
	hkdf2(n->ck, input, 32, nck, n->k);
	memcpy(n->ck, nck, 32);
	n->haveK = true;
	n->nonce = 0;
}

static bool mix_dh(coop_noise* n, const uint8_t secret[32], const uint8_t pub[32]) {
	uint8_t shared[32];
	if (!coop_x25519(secret, pub, shared)) {
		return false;
	}
	mix_key(n, shared);
	coop_wipe(shared, sizeof shared);
	return true;
}

static size_t encrypt_and_hash(coop_noise* n, const uint8_t* plain, size_t len, uint8_t* out) {
	size_t outLen = len;
	if (n->haveK) {
		uint8_t iv[12];
		nonce_of(n->nonce++, iv);
		coop_aesgcm_encrypt(n->k, iv, n->h, 32, plain, len, out);
		outLen += 16;
	} else {
		memmove(out, plain, len);
	}
	mix_hash(n, out, outLen);
	return outLen;
}

static long decrypt_and_hash(coop_noise* n, const uint8_t* sealed, size_t len, uint8_t* out) {
	long outLen = (long) len;
	if (n->haveK) {
		uint8_t iv[12];
		nonce_of(n->nonce, iv);
		if (len < 16 || !coop_aesgcm_decrypt(n->k, iv, n->h, 32, sealed, len, out)) {
			return -1;
		}
		n->nonce++;
		outLen -= 16;
	} else {
		memmove(out, sealed, len);
	}
	mix_hash(n, sealed, len);
	return outLen;
}

void coop_noise_init(coop_noise* n, bool initiator, const uint8_t s[32], const uint8_t* rs, const uint8_t* prologue,
                     size_t prologueLen, const uint8_t* fixedEphemeral) {
	memset(n, 0, sizeof *n);
	n->initiator = initiator;
	memcpy(n->s, s, 32);
	coop_x25519_public(s, n->sPub);
	if (rs) {
		memcpy(n->rs, rs, 32);
		n->haveRs = true;
	}
	if (fixedEphemeral) {
		memcpy(n->e, fixedEphemeral, 32);
		n->fixedE = true;
	}
	memcpy(n->h, PROTOCOL, sizeof PROTOCOL - 1); // 28 bytes, zero-padded to 32
	memcpy(n->ck, n->h, 32);
	mix_hash(n, prologue, prologueLen);
	// The pre-message `<- s`.
	mix_hash(n, initiator ? n->rs : n->sPub, 32);
}

bool coop_noise_done(const coop_noise* n) { return n->step == 2 && !n->failed; }

size_t coop_noise_write(coop_noise* n, const uint8_t* payload, size_t len, uint8_t* out) {
	if (n->failed || (n->initiator ? n->step != 0 : n->step != 1)) {
		return 0;
	}
	if (!n->fixedE) {
		coop_random(n->e, 32);
	}
	coop_x25519_public(n->e, n->ePub);
	n->haveE = true;
	size_t at = 0;
	memcpy(out, n->ePub, 32);
	at += 32;
	mix_hash(n, n->ePub, 32);
	if (n->initiator) {
		if (!mix_dh(n, n->e, n->rs)) { // es
			n->failed = true;
			return 0;
		}
		at += encrypt_and_hash(n, n->sPub, 32, out + at);
		if (!mix_dh(n, n->s, n->rs)) { // ss
			n->failed = true;
			return 0;
		}
	} else {
		if (!mix_dh(n, n->e, n->re) || !mix_dh(n, n->e, n->rs)) { // ee, se
			n->failed = true;
			return 0;
		}
	}
	at += encrypt_and_hash(n, payload, len, out + at);
	n->step++;
	return at;
}

long coop_noise_read(coop_noise* n, const uint8_t* m, size_t len, uint8_t* payload) {
	if (n->failed || (n->initiator ? n->step != 1 : n->step != 0)) {
		return -1;
	}
	size_t min = n->initiator ? 32 + 16 : 32 + 32 + 16 + 16;
	long result = -1;
	if (len >= min) {
		memcpy(n->re, m, 32);
		n->haveRe = true;
		mix_hash(n, n->re, 32);
		size_t off = 32;
		bool ok;
		if (n->initiator) {
			ok = mix_dh(n, n->e, n->re) && mix_dh(n, n->s, n->re); // ee, se
		} else {
			uint8_t staticPub[32];
			ok = mix_dh(n, n->s, n->re) && decrypt_and_hash(n, m + off, 48, staticPub) == 32; // es, s
			if (ok) {
				off += 48;
				memcpy(n->rs, staticPub, 32);
				n->haveRs = true;
				ok = mix_dh(n, n->s, n->rs); // ss
			}
		}
		if (ok) {
			result = decrypt_and_hash(n, m + off, len - off, payload);
		}
	}
	if (result < 0) {
		n->failed = true;
	} else {
		n->step++;
	}
	return result;
}

void coop_noise_split(coop_noise* n, coop_cipher* send, coop_cipher* receive) {
	uint8_t k1[32], k2[32];
	hkdf2(n->ck, NULL, 0, k1, k2);
	memcpy(send->key, n->initiator ? k1 : k2, 32);
	memcpy(receive->key, n->initiator ? k2 : k1, 32);
	send->n = receive->n = 0;
	coop_wipe(k1, sizeof k1);
	coop_wipe(k2, sizeof k2);
	coop_wipe(n->e, 32);
	coop_wipe(n->k, 32);
}

/* ---- the channel ---- */

enum { KIND_DATA = 0, KIND_PING = 1, KIND_CLOSE = 2 };
#define TRANSPORT_VERSION 1

size_t coop_prologue(int path, const char* room, uint8_t out[64]) {
	static const char TEXT[] = "PokeDaisy co-op 1";
	size_t at = sizeof TEXT - 1;
	memcpy(out, TEXT, at);
	out[at++] = (uint8_t) path;
	if (path != COOP_PATH_TCP && room && strlen(room) == 32) {
		memcpy(out + at, room, 32);
		at += 32;
	}
	return at;
}

void coop_channel_init(coop_channel* ch, bool initiator, const uint8_t ownSecret[32], const uint8_t* remoteStatic,
                       const uint8_t* prologue, size_t prologueLen, int64_t now, coop_channel_events ev) {
	memset(ch, 0, sizeof *ch);
	ch->initiator = initiator;
	ch->startedAt = now;
	ch->ev = ev;
	coop_noise_init(&ch->noise, initiator, ownSecret, remoteStatic, prologue, prologueLen, NULL);
}

static void pipe_bytes(coop_channel* ch, const uint8_t* b, size_t n) { ch->ev.pipe(ch->ev.ctx, ch, b, n); }

static void sealed(coop_channel* ch, const uint8_t* plain, size_t n) {
	uint8_t* out = malloc(n + 16);
	if (!out) {
		return;
	}
	coop_cipher_encrypt(&ch->send, plain, n, out);
	pipe_bytes(ch, out, n + 16);
	free(out);
}

static void tell_peer(coop_channel* ch, int code) {
	if (!ch->open) {
		return;
	}
	uint8_t m[2] = {KIND_CLOSE, (uint8_t) code};
	sealed(ch, m, 2);
}

static void fail(coop_channel* ch, int code, bool beforeOpen, bool tell) {
	if (tell) {
		tell_peer(ch, code);
	}
	ch->done = true;
	if (ch->ev.closed) {
		ch->ev.closed(ch->ev.ctx, ch, code, beforeOpen);
	}
}

static void finish(coop_channel* ch, int64_t now) {
	coop_noise_split(&ch->noise, &ch->send, &ch->receive);
	ch->open = true;
	ch->lastReceived = ch->lastPing = ch->openedAt = now;
	memcpy(ch->remote, ch->noise.rs, 32);
	if (ch->ev.opened) {
		ch->ev.opened(ch->ev.ctx, ch, ch->remote);
	}
}

void coop_channel_begin(coop_channel* ch) {
	if (ch->done || !ch->initiator || ch->began) {
		return;
	}
	ch->began = true;
	uint8_t payload[2] = {0, TRANSPORT_VERSION}, msg[32 + 48 + 2 + 16];
	size_t n = coop_noise_write(&ch->noise, payload, 2, msg);
	if (n) {
		pipe_bytes(ch, msg, n);
	} else {
		fail(ch, COOP_ERROR, true, false);
	}
}

static void refuse(coop_channel* ch, int status) {
	uint8_t s = (uint8_t) status, msg[32 + 1 + 16];
	size_t n = coop_noise_write(&ch->noise, &s, 1, msg);
	if (n) {
		pipe_bytes(ch, msg, n);
	}
	fail(ch, status, true, false);
}

void coop_channel_receive(coop_channel* ch, const uint8_t* msg, size_t n, int64_t now) {
	if (ch->done) {
		return;
	}
	if (ch->open) {
		if (n < 16) {
			fail(ch, COOP_ERROR, false, true);
			return;
		}
		uint8_t* plain = malloc(n);
		if (!plain) {
			return;
		}
		if (!coop_cipher_decrypt(&ch->receive, msg, n, plain) || n == 16) {
			free(plain);
			fail(ch, COOP_ERROR, false, true);
			return;
		}
		size_t len = n - 16;
		ch->lastReceived = now;
		switch (plain[0]) {
		case KIND_DATA:
			if (len - 1 > COOP_MAX_APP_FRAME) {
				fail(ch, COOP_OVERFLOW, false, true);
			} else if (len == 1) {
				fail(ch, COOP_ERROR, false, true);
			} else if (ch->ev.frame) {
				ch->ev.frame(ch->ev.ctx, ch, plain + 1, len - 1);
			}
			break;
		case KIND_PING:
			if (len != 1) {
				fail(ch, COOP_ERROR, false, true);
			}
			break;
		case KIND_CLOSE:
			if (len == 2) {
				fail(ch, plain[1], false, false);
			} else {
				fail(ch, COOP_ERROR, false, true);
			}
			break;
		default:
			fail(ch, COOP_ERROR, false, true);
		}
		free(plain);
		return;
	}
	uint8_t* payload = malloc(n + 1);
	if (!payload) {
		return;
	}
	if (ch->initiator) {
		if (ch->began) {
			long len = coop_noise_read(&ch->noise, msg, n, payload);
			if (len < 0) {
				fail(ch, COOP_ERROR, true, false);
			} else {
				int status = len == 1 ? payload[0] : COOP_ERROR;
				if (status) {
					fail(ch, status, true, false);
				} else {
					finish(ch, now);
				}
			}
		}
	} else {
		long len = coop_noise_read(&ch->noise, msg, n, payload);
		if (len < 0) {
			fail(ch, COOP_ERROR, true, false);
		} else {
			int version = len == 2 ? (payload[0] << 8 | payload[1]) : -1;
			if (version != TRANSPORT_VERSION) {
				refuse(ch, COOP_VERSION);
			} else {
				int status = ch->ev.decide ? ch->ev.decide(ch->ev.ctx, ch, ch->noise.rs) : 0;
				if (!ch->done) {
					if (status) {
						refuse(ch, status);
					} else {
						uint8_t ok = 0, m2[32 + 1 + 16];
						size_t m = coop_noise_write(&ch->noise, &ok, 1, m2);
						if (m) {
							pipe_bytes(ch, m2, m);
							finish(ch, now);
						} else {
							fail(ch, COOP_ERROR, true, false);
						}
					}
				}
			}
		}
	}
	free(payload);
}

bool coop_channel_send(coop_channel* ch, const uint8_t* frame, size_t n) {
	if (ch->done || !ch->open || n < 1 || n > COOP_MAX_APP_FRAME) {
		return false;
	}
	uint8_t* plain = malloc(n + 1);
	if (!plain) {
		return false;
	}
	plain[0] = KIND_DATA;
	memcpy(plain + 1, frame, n);
	uint8_t* out = malloc(n + 1 + 16);
	bool ok = false;
	if (out) {
		coop_cipher_encrypt(&ch->send, plain, n + 1, out);
		ok = ch->ev.pipe(ch->ev.ctx, ch, out, n + 1 + 16);
		free(out);
	}
	free(plain);
	return ok;
}

void coop_channel_close(coop_channel* ch, int code) {
	if (ch->done) {
		return;
	}
	tell_peer(ch, code);
	ch->done = true;
}

void coop_channel_tick(coop_channel* ch, int64_t now) {
	if (ch->done) {
		return;
	}
	if (!ch->open) {
		if (now - ch->startedAt >= COOP_HANDSHAKE_MS) {
			fail(ch, COOP_TIMEOUT, true, true);
		}
	} else if (now - ch->lastReceived >= COOP_IDLE_MS) {
		fail(ch, COOP_TIMEOUT, false, true);
	} else if (now - ch->lastPing >= COOP_PING_MS) {
		ch->lastPing = now;
		uint8_t ping = KIND_PING;
		sealed(ch, &ping, 1);
	}
}

void coop_channel_pipe_closed(coop_channel* ch) {
	if (ch->done) {
		return;
	}
	fail(ch, COOP_ERROR, !ch->open, false);
}
