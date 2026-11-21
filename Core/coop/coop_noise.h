/* PokeDaisy's co-op link, its secure channel: Noise_IK_25519_AESGCM_SHA256 (the IK pattern only) and the session
 * framing on top (CoopNoise.kt, CoopChannel.kt in the app: the same bytes on the wire). Licensed under the GNU GPL v3. */
#ifndef COOP_NOISE_H
#define COOP_NOISE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 32 random bytes from the system. */
void coop_random(void* out, size_t n);

/* One direction of a finished handshake: AES-256-GCM, nonce = 4 zero bytes + an 8-byte big-endian counter, no
 * associated data. decrypt counts the nonce only on success. */
typedef struct {
	uint8_t key[32];
	uint64_t n;
} coop_cipher;

/* out: n + 16 bytes. */
void coop_cipher_encrypt(coop_cipher* c, const uint8_t* in, size_t n, uint8_t* out);
/* in: n >= 16 bytes; out: n - 16. False when it doesn't authenticate. */
bool coop_cipher_decrypt(coop_cipher* c, const uint8_t* in, size_t n, uint8_t* out);

typedef struct {
	bool initiator, failed, haveK, haveRs, haveE, haveRe;
	int step;
	uint8_t ck[32], h[32], k[32];
	uint64_t nonce;
	uint8_t s[32], sPub[32], rs[32], e[32], ePub[32], re[32];
	bool fixedE;
} coop_noise;

/* rs: the responder's static public key (initiator only). fixedEphemeral: tests only, else NULL. */
void coop_noise_init(coop_noise* n, bool initiator, const uint8_t s[32], const uint8_t* rs, const uint8_t* prologue,
                     size_t prologueLen, const uint8_t* fixedEphemeral);
/* The next handshake message carrying payload into out (room for 32 + 48 + n + 16): its length, 0 if not this side's turn. */
size_t coop_noise_write(coop_noise* n, const uint8_t* payload, size_t len, uint8_t* out);
/* The peer's handshake message: its payload's length into payload (room for len), -1 when it fails (the handshake is dead). */
long coop_noise_read(coop_noise* n, const uint8_t* msg, size_t len, uint8_t* payload);
bool coop_noise_done(const coop_noise* n);
/* The send / receive ciphers, once done. */
void coop_noise_split(coop_noise* n, coop_cipher* send, coop_cipher* receive);

/* ---- the channel (CoopChannel) ---- */

enum {
	COOP_CLOSED = 0,
	COOP_TIMEOUT = 1,
	COOP_DENIED = 2,
	COOP_VERSION = 3,
	COOP_NOT_ALLOWED = 4,
	COOP_OVERFLOW = 5,
	COOP_ERROR = 6,
	COOP_PENDING_EXPIRED = 7,
	COOP_DUPLICATE = 8
};

enum { COOP_PATH_INVITE = 0, COOP_PATH_PAIR = 1, COOP_PATH_TCP = 2 };

#define COOP_MAX_APP_FRAME 65536
#define COOP_MAX_TCP_FRAME 70000
#define COOP_HANDSHAKE_MS 5000
#define COOP_PING_MS 5000
#define COOP_IDLE_MS 20000

typedef struct coop_channel coop_channel;

typedef struct {
	void* ctx;
	/* One message to the peer (a whole TCP frame's body); only queue it. */
	bool (*pipe)(void* ctx, coop_channel* ch, const uint8_t* bytes, size_t n);
	/* Responder: 0 to go on, else the reason code to refuse the initiator (its key). */
	int (*decide)(void* ctx, coop_channel* ch, const uint8_t remote[32]);
	void (*opened)(void* ctx, coop_channel* ch, const uint8_t remote[32]);
	void (*frame)(void* ctx, coop_channel* ch, const uint8_t* bytes, size_t n);
	/* Not called for our own close. beforeOpen: the handshake never finished. */
	void (*closed)(void* ctx, coop_channel* ch, int code, bool beforeOpen);
} coop_channel_events;

struct coop_channel {
	coop_noise noise;
	coop_cipher send, receive;
	bool initiator, open, done, began;
	int64_t startedAt, lastReceived, lastPing, openedAt;
	uint8_t remote[32];
	coop_channel_events ev;
};

/* The handshake prologue: "PokeDaisy co-op 1", the path byte and (relay rooms) the room's 32 characters. Its length. */
size_t coop_prologue(int path, const char* room, uint8_t out[64]);

void coop_channel_init(coop_channel* ch, bool initiator, const uint8_t ownSecret[32], const uint8_t* remoteStatic,
                       const uint8_t* prologue, size_t prologueLen, int64_t now, coop_channel_events ev);
/* The initiator sends message 1. */
void coop_channel_begin(coop_channel* ch);
/* One message from the pipe (untrusted). */
void coop_channel_receive(coop_channel* ch, const uint8_t* msg, size_t n, int64_t now);
/* A frame of 1..65,536 bytes; false unless open. */
bool coop_channel_send(coop_channel* ch, const uint8_t* frame, size_t n);
/* Closes with code, telling the peer once open; no callback. */
void coop_channel_close(coop_channel* ch, int code);
/* Pings, and times out a silent session or a slow handshake. */
void coop_channel_tick(coop_channel* ch, int64_t now);
/* The pipe went away. */
void coop_channel_pipe_closed(coop_channel* ch);

#ifdef __cplusplus
}
#endif

#endif
