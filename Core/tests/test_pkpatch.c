/* pk_patch: xdelta patches made by the xdelta3 CLI (none, DJW, LZMA and its default secondary compression),
 * a hand-built IPS, and refusing the wrong source. The source ROM is generated here; tests/data/patch holds the
 * patches (made from it with xdelta3 3.1). */
#include "pkcore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static uint8_t* load(const char* path, size_t* size) {
	FILE* f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	*size = (size_t) ftell(f);
	rewind(f);
	uint8_t* data = malloc(*size);
	if (fread(data, 1, *size, f) != *size) *size = 0;
	fclose(f);
	return data;
}

int main(void) {
	uint8_t src[1 << 16];
	uint32_t x = 1;
	for (size_t i = 0; i < sizeof src; ++i) {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		src[i] = (uint8_t) (0x61 + (x & 0x0f));
	}
	CHECK(pk_crc32(src, sizeof src) == 0x737ad5d4u);

	const char* kinds[] = {"none", "djw", "lzma", "default"};
	for (int k = 0; k < 4; ++k) {
		char path[512];
		snprintf(path, sizeof path, "%s/patch/hack_%s.xdelta", TEST_DATA, kinds[k]);
		size_t n = 0;
		uint8_t* patch = load(path, &n);
		CHECK(patch && n);
		if (!patch) continue;
		CHECK(pk_patch_format(patch, n) == PK_PATCH_XDELTA);
		uint8_t* out = NULL;
		size_t outSize = 0;
		int r = pk_patch_apply(src, sizeof src, patch, n, &out, &outSize);
		if (r) printf("%s: %d\n", kinds[k], r);
		CHECK(r == PK_PATCH_OK && outSize == 95616 && pk_crc32(out, outSize) == 0x60bfbb5cu);
		pk_patch_free(out);

		/* Another ROM: refused (the window checksums don't match). */
		uint8_t other[sizeof src];
		memcpy(other, src, sizeof src);
		for (size_t i = 0; i < sizeof other; i += 97) other[i] ^= 0x5a;
		out = NULL;
		r = pk_patch_apply(other, sizeof other, patch, n, &out, &outSize);
		CHECK(r == PK_PATCH_ERR_WRONG_SOURCE || r == PK_PATCH_ERR_RESULT);
		pk_patch_free(out);
		free(patch);
	}

	/* IPS: two records, one growing the file. */
	const uint8_t ips[] = {'P', 'A', 'T', 'C', 'H', 0, 0, 4, 0, 2, 'O', 'K', 1, 0, 0, 0, 3, 'E', 'N', 'D', 'E', 'O', 'F'};
	CHECK(pk_patch_format(ips, sizeof ips) == PK_PATCH_IPS);
	uint8_t* out = NULL;
	size_t outSize = 0;
	CHECK(pk_patch_apply(src, sizeof src, ips, sizeof ips, &out, &outSize) == PK_PATCH_OK);
	CHECK(outSize == 0x10003 && out && !memcmp(out + 4, "OK", 2) && !memcmp(out + 0x10000, "END", 3)
		&& out[0] == src[0] && out[6] == src[6]);
	pk_patch_free(out);

	CHECK(pk_patch_format((const uint8_t*) "nothing", 7) == PK_PATCH_UNKNOWN);
	printf(failures ? "pkpatch: %d failure(s)\n" : "pkpatch: ok\n", failures);
	return failures != 0;
}
