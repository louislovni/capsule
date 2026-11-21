/* Co-op crypto (coop_crypto.h). SHA-256 per FIPS 180-4, AES per FIPS 197, GCM per NIST SP 800-38D; X25519 is
 * Monocypher's (third_party/monocypher, BSD-2 / CC0). Licensed under the GNU GPL v3. */
#include "coop_crypto.h"

#include <string.h>

#include "monocypher.h"

/* ---- SHA-256 ---- */

static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
    0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
    0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t h[8], const uint8_t* p) {
	uint32_t w[64];
	for (int i = 0; i < 16; i++) {
		w[i] = (uint32_t) p[i * 4] << 24 | (uint32_t) p[i * 4 + 1] << 16 | (uint32_t) p[i * 4 + 2] << 8 | p[i * 4 + 3];
	}
	for (int i = 16; i < 64; i++) {
		uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
		uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
	for (int i = 0; i < 64; i++) {
		uint32_t t1 = k + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
		uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		k = g;
		g = f;
		f = e;
		e = d + t1;
		d = c;
		c = b;
		b = a;
		a = t1 + t2;
	}
	h[0] += a;
	h[1] += b;
	h[2] += c;
	h[3] += d;
	h[4] += e;
	h[5] += f;
	h[6] += g;
	h[7] += k;
}

void coop_sha256_init(coop_sha256_ctx* c) {
	static const uint32_t H0[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
	memcpy(c->h, H0, sizeof H0);
	c->length = 0;
	c->used = 0;
}

void coop_sha256_update(coop_sha256_ctx* c, const void* data, size_t n) {
	const uint8_t* p = data;
	c->length += n;
	while (n) {
		size_t take = 64 - c->used < n ? 64 - c->used : n;
		memcpy(c->block + c->used, p, take);
		c->used += take;
		p += take;
		n -= take;
		if (c->used == 64) {
			sha256_block(c->h, c->block);
			c->used = 0;
		}
	}
}

void coop_sha256_final(coop_sha256_ctx* c, uint8_t out[32]) {
	uint64_t bits = c->length * 8;
	uint8_t pad = 0x80;
	coop_sha256_update(c, &pad, 1);
	pad = 0;
	while (c->used != 56) {
		coop_sha256_update(c, &pad, 1);
	}
	uint8_t len[8];
	for (int i = 0; i < 8; i++) {
		len[i] = (uint8_t) (bits >> (56 - 8 * i));
	}
	coop_sha256_update(c, len, 8);
	for (int i = 0; i < 8; i++) {
		out[i * 4] = (uint8_t) (c->h[i] >> 24);
		out[i * 4 + 1] = (uint8_t) (c->h[i] >> 16);
		out[i * 4 + 2] = (uint8_t) (c->h[i] >> 8);
		out[i * 4 + 3] = (uint8_t) c->h[i];
	}
	coop_wipe(c, sizeof *c);
}

void coop_sha256(const void* data, size_t n, uint8_t out[32]) {
	coop_sha256_ctx c;
	coop_sha256_init(&c);
	coop_sha256_update(&c, data, n);
	coop_sha256_final(&c, out);
}

void coop_hmac_sha256(const uint8_t* key, size_t keyLen, const void* a, size_t aLen, const void* b, size_t bLen,
                      uint8_t out[32]) {
	uint8_t k[64] = {0}, pad[64], inner[32];
	if (keyLen > 64) {
		coop_sha256(key, keyLen, k);
	} else if (keyLen) {
		memcpy(k, key, keyLen);
	}
	coop_sha256_ctx c;
	for (int i = 0; i < 64; i++) {
		pad[i] = k[i] ^ 0x36;
	}
	coop_sha256_init(&c);
	coop_sha256_update(&c, pad, 64);
	if (aLen) {
		coop_sha256_update(&c, a, aLen);
	}
	if (bLen) {
		coop_sha256_update(&c, b, bLen);
	}
	coop_sha256_final(&c, inner);
	for (int i = 0; i < 64; i++) {
		pad[i] = k[i] ^ 0x5c;
	}
	coop_sha256_init(&c);
	coop_sha256_update(&c, pad, 64);
	coop_sha256_update(&c, inner, 32);
	coop_sha256_final(&c, out);
	coop_wipe(k, sizeof k);
	coop_wipe(pad, sizeof pad);
	coop_wipe(inner, sizeof inner);
}

/* ---- AES-256 ---- */

static const uint8_t SBOX[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d,
    0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc,
    0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15, 0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
    0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf, 0xd0, 0xef, 0xaa, 0xfb,
    0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
    0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d,
    0x64, 0x5d, 0x19, 0x73, 0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
    0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08, 0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6,
    0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9,
    0x86, 0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16};

static uint8_t xtime(uint8_t x) { return (uint8_t) ((x << 1) ^ ((x >> 7) * 0x1b)); }

typedef struct {
	uint8_t rk[240];
} aes256;

static void aes256_init(aes256* a, const uint8_t key[32]) {
	memcpy(a->rk, key, 32);
	uint8_t rcon = 1;
	for (int i = 32; i < 240; i += 4) {
		uint8_t t[4];
		memcpy(t, a->rk + i - 4, 4);
		if (i % 32 == 0) {
			uint8_t u = t[0];
			t[0] = (uint8_t) (SBOX[t[1]] ^ rcon);
			t[1] = SBOX[t[2]];
			t[2] = SBOX[t[3]];
			t[3] = SBOX[u];
			rcon = xtime(rcon);
		} else if (i % 32 == 16) {
			for (int j = 0; j < 4; j++) {
				t[j] = SBOX[t[j]];
			}
		}
		for (int j = 0; j < 4; j++) {
			a->rk[i + j] = a->rk[i - 32 + j] ^ t[j];
		}
	}
}

static void aes256_block(const aes256* a, const uint8_t in[16], uint8_t out[16]) {
	uint8_t s[16];
	for (int i = 0; i < 16; i++) {
		s[i] = in[i] ^ a->rk[i];
	}
	for (int round = 1; round <= 14; round++) {
		uint8_t t[16];
		// SubBytes and ShiftRows (column-major state: byte r + 4c).
		for (int c = 0; c < 4; c++) {
			for (int r = 0; r < 4; r++) {
				t[r + 4 * c] = SBOX[s[r + 4 * ((c + r) % 4)]];
			}
		}
		if (round < 14) {
			for (int c = 0; c < 4; c++) {
				uint8_t* col = t + 4 * c;
				uint8_t a0 = col[0], a1 = col[1], a2 = col[2], a3 = col[3], all = a0 ^ a1 ^ a2 ^ a3;
				col[0] = a0 ^ all ^ xtime(a0 ^ a1);
				col[1] = a1 ^ all ^ xtime(a1 ^ a2);
				col[2] = a2 ^ all ^ xtime(a2 ^ a3);
				col[3] = a3 ^ all ^ xtime(a3 ^ a0);
			}
		}
		for (int i = 0; i < 16; i++) {
			s[i] = t[i] ^ a->rk[round * 16 + i];
		}
	}
	memcpy(out, s, 16);
}

/* ---- GCM ---- */

/* x * y in GF(2^128), GCM's bit order (the bit-by-bit method: no table, no secret-dependent branches). */
static void gf_mul(uint8_t x[16], const uint8_t y[16]) {
	uint8_t z[16] = {0}, v[16];
	memcpy(v, y, 16);
	for (int i = 0; i < 128; i++) {
		uint8_t bit = (uint8_t) -((x[i / 8] >> (7 - i % 8)) & 1);
		for (int j = 0; j < 16; j++) {
			z[j] ^= v[j] & bit;
		}
		uint8_t lsb = (uint8_t) -(v[15] & 1);
		for (int j = 15; j > 0; j--) {
			v[j] = (uint8_t) ((v[j] >> 1) | (v[j - 1] << 7));
		}
		v[0] >>= 1;
		v[0] ^= 0xe1 & lsb;
	}
	memcpy(x, z, 16);
}

static void ghash_update(uint8_t y[16], const uint8_t h[16], const uint8_t* p, size_t n) {
	while (n) {
		size_t take = n < 16 ? n : 16;
		for (size_t i = 0; i < take; i++) {
			y[i] ^= p[i];
		}
		gf_mul(y, h);
		p += take;
		n -= take;
	}
}

static void gcm_core(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* ad, size_t adLen, const uint8_t* in,
                     size_t n, uint8_t* out, bool encrypt, uint8_t tag[16]) {
	aes256 a;
	aes256_init(&a, key);
	uint8_t h[16] = {0}, j0[16], ctr[16], ks[16], y[16] = {0};
	aes256_block(&a, h, h);
	memcpy(j0, nonce, 12);
	j0[12] = j0[13] = j0[14] = 0;
	j0[15] = 1;
	ghash_update(y, h, ad, adLen);
	if (!encrypt) {
		ghash_update(y, h, in, n);
	}
	memcpy(ctr, j0, 16);
	for (size_t off = 0; off < n; off += 16) {
		for (int i = 15; i >= 12; i--) {
			if (++ctr[i]) {
				break;
			}
		}
		aes256_block(&a, ctr, ks);
		size_t take = n - off < 16 ? n - off : 16;
		for (size_t i = 0; i < take; i++) {
			out[off + i] = in[off + i] ^ ks[i];
		}
	}
	if (encrypt) {
		ghash_update(y, h, out, n);
	}
	uint8_t lens[16];
	uint64_t abits = (uint64_t) adLen * 8, cbits = (uint64_t) n * 8;
	for (int i = 0; i < 8; i++) {
		lens[i] = (uint8_t) (abits >> (56 - 8 * i));
		lens[8 + i] = (uint8_t) (cbits >> (56 - 8 * i));
	}
	ghash_update(y, h, lens, 16);
	aes256_block(&a, j0, ks);
	for (int i = 0; i < 16; i++) {
		tag[i] = y[i] ^ ks[i];
	}
	coop_wipe(&a, sizeof a);
	coop_wipe(h, sizeof h);
	coop_wipe(ks, sizeof ks);
}

void coop_aesgcm_encrypt(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* ad, size_t adLen,
                         const uint8_t* in, size_t n, uint8_t* out) {
	uint8_t tag[16];
	gcm_core(key, nonce, ad, adLen, in, n, out, true, tag);
	memcpy(out + n, tag, 16);
}

bool coop_aesgcm_decrypt(const uint8_t key[32], const uint8_t nonce[12], const uint8_t* ad, size_t adLen,
                         const uint8_t* in, size_t n, uint8_t* out) {
	if (n < 16) {
		return false;
	}
	size_t body = n - 16;
	uint8_t want[16], tag[16];
	memcpy(tag, in + body, 16); // in may be out
	// The tag is checked before anything is written out: decrypt into out only once it matches.
	aes256 a;
	aes256_init(&a, key);
	uint8_t h[16] = {0}, j0[16], y[16] = {0}, ks[16];
	aes256_block(&a, h, h);
	memcpy(j0, nonce, 12);
	j0[12] = j0[13] = j0[14] = 0;
	j0[15] = 1;
	ghash_update(y, h, ad, adLen);
	ghash_update(y, h, in, body);
	uint8_t lens[16];
	uint64_t abits = (uint64_t) adLen * 8, cbits = (uint64_t) body * 8;
	for (int i = 0; i < 8; i++) {
		lens[i] = (uint8_t) (abits >> (56 - 8 * i));
		lens[8 + i] = (uint8_t) (cbits >> (56 - 8 * i));
	}
	ghash_update(y, h, lens, 16);
	aes256_block(&a, j0, ks);
	uint8_t diff = 0;
	for (int i = 0; i < 16; i++) {
		want[i] = y[i] ^ ks[i];
		diff |= want[i] ^ tag[i];
	}
	coop_wipe(&a, sizeof a);
	if (diff) {
		return false;
	}
	uint8_t ignored[16];
	gcm_core(key, nonce, NULL, 0, in, body, out, false, ignored);
	return true;
}

/* ---- X25519 ---- */

void coop_x25519_public(const uint8_t secret[32], uint8_t pub[32]) { crypto_x25519_public_key(pub, secret); }

bool coop_x25519(const uint8_t secret[32], const uint8_t pub[32], uint8_t shared[32]) {
	crypto_x25519(shared, secret, pub);
	uint8_t any = 0;
	for (int i = 0; i < 32; i++) {
		any |= shared[i];
	}
	return any != 0;
}

void coop_wipe(void* p, size_t n) { crypto_wipe(p, n); }
