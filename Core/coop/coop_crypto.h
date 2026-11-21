/* Co-op crypto: what PokeDaisy's co-op link (Noise_IK_25519_AESGCM_SHA256) needs, in plain C so the iPhone app and the
 * PC host share it: SHA-256, HMAC-SHA256, AES-256-GCM and X25519 (Monocypher's). Licensed under the GNU GPL v3. */
#ifndef COOP_CRYPTO_H
#define COOP_CRYPTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
	uint32_t h[8];
	uint64_t length;
	uint8_t block[64];
	size_t used;
} coop_sha256_ctx;

/* SHA-1 of a whole buffer: the ROM's fingerprint (what the HELLO names), not for security. */
void coop_sha1(const void* data, size_t n, uint8_t out[20]);

void coop_sha256_init(coop_sha256_ctx* c);
void coop_sha256_update(coop_sha256_ctx* c, const void* data, size_t n);
void coop_sha256_final(coop_sha256_ctx* c, uint8_t out[32]);
void coop_sha256(const void* data, size_t n, uint8_t out[32]);

/* HMAC-SHA256 over the concatenation of two parts (b may be NULL / 0). */
void coop_hmac_sha256(const uint8_t* key, size_t keyLen, const void* a, size_t aLen, const void* b, size_t bLen,
                      uint8_t out[32]);

/* AES-256-GCM, a 12-byte nonce, a 16-byte tag after the ciphertext. encrypt writes n + 16 bytes; decrypt reads n
 * (>= 16) and writes n - 16, false when the tag doesn't match (nothing is trusted then). out may equal in. */
void coop_aesgcm_encrypt(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* ad, size_t adLen,
                         const uint8_t* in, size_t n, uint8_t* out);
bool coop_aesgcm_decrypt(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* ad, size_t adLen,
                         const uint8_t* in, size_t n, uint8_t* out);

/* X25519: the public key of a secret; the shared secret, false when it is all zero (a low-order public key). */
void coop_x25519_public(const uint8_t secret[32], uint8_t pub[32]);
bool coop_x25519(const uint8_t secret[32], const uint8_t pub[32], uint8_t shared[32]);

/* Wipes a buffer the compiler can't skip. */
void coop_wipe(void* p, size_t n);

#ifdef __cplusplus
}
#endif

#endif
