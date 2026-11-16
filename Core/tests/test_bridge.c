/* Smoke test for lr_bridge over the PokeDaisy core, with tiny ROMs assembled
 * here (no game needed). Built and run by scripts/build_core.sh host. */
#define _DEFAULT_SOURCE
#include "lr_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;
#define CHECK(cond) \
	do { \
		if (!(cond)) { \
			++failures; \
			printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
		} \
	} while (0)

static void put32(uint8_t* p, uint32_t v) {
	p[0] = (uint8_t) v;
	p[1] = (uint8_t) (v >> 8);
	p[2] = (uint8_t) (v >> 16);
	p[3] = (uint8_t) (v >> 24);
}

static void write_gba_rom(const char* path) {
	uint8_t rom[0x200];
	memset(rom, 0, sizeof(rom));
	put32(rom, 0xEA00002E); /* b 0x080000C0 */
	memcpy(rom + 0xA0, "CAPSULETEST", 11);
	memcpy(rom + 0xAC, "ZTSE", 4);
	rom[0xB2] = 0x96;
	static const uint32_t code[] = {
		0xE3A00301, /* mov  r0, #0x04000000 */
		0xE3A01B01, /* mov  r1, #0x400 */
		0xE2811003, /* add  r1, r1, #3   ; mode 3, BG2 on */
		0xE1C010B0, /* strh r1, [r0] */
		0xE3A02406, /* mov  r2, #0x06000000 */
		0xE3A0301F, /* mov  r3, #0x1F    ; red */
		0xE1C230B0, /* strh r3, [r2] */
		0xEAFFFFFE, /* b    . */
	};
	for (size_t i = 0; i < sizeof(code) / sizeof(code[0]); ++i) {
		put32(rom + 0xC0 + i * 4, code[i]);
	}
	FILE* f = fopen(path, "wb");
	fwrite(rom, 1, sizeof(rom), f);
	fclose(f);
}

static void write_gb_rom(const char* path) {
	enum { SIZE = 0x8000 };
	uint8_t* rom = calloc(1, SIZE);
	static const uint8_t entry[] = { 0x00, 0xC3, 0x50, 0x01 };
	memcpy(rom + 0x100, entry, sizeof(entry));
	static const uint8_t logo[] = { 0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83,
		                            0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
		                            0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63,
		                            0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E };
	memcpy(rom + 0x104, logo, sizeof(logo));
	memcpy(rom + 0x134, "CAPSULEGB", 9);
	rom[0x143] = 0x80;
	static const uint8_t code[] = { 0x18, 0xFE }; /* jr . */
	memcpy(rom + 0x150, code, sizeof(code));
	uint8_t check = 0;
	for (int i = 0x134; i <= 0x14C; ++i) {
		check = (uint8_t) (check - rom[i] - 1);
	}
	rom[0x14D] = check;
	FILE* f = fopen(path, "wb");
	fwrite(rom, 1, SIZE, f);
	fclose(f);
	free(rom);
}

static size_t drain(LRCore* core) {
	int16_t audio[4096 * 2];
	size_t total = 0, got;
	while ((got = lr_audio_read(core, audio, 4096)) > 0) {
		total += got;
	}
	return total;
}

static long file_size(const char* path) {
	FILE* f = fopen(path, "rb");
	if (!f) {
		return -1;
	}
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fclose(f);
	return size;
}

int main(void) {
	char dir[] = "/tmp/capsule-lr-XXXXXX";
	if (!mkdtemp(dir)) {
		return 2;
	}
	char rom[256], gb[256], sav[256], gbsav[256], state[256], data[256];
	snprintf(rom, sizeof(rom), "%s/test.gba", dir);
	snprintf(gb, sizeof(gb), "%s/test.gbc", dir);
	snprintf(sav, sizeof(sav), "%s/test.sav", dir);
	snprintf(gbsav, sizeof(gbsav), "%s/test-gb.sav", dir);
	snprintf(state, sizeof(state), "%s/test.ss1", dir);
	snprintf(data, sizeof(data), "%s/data", dir);
	write_gba_rom(rom);
	write_gb_rom(gb);

	CHECK(lr_create("/nonexistent/file.gba", sav, data, "auto") == NULL);

	/* A battery save that exists is loaded and left alone while nothing changes. */
	enum { SAVE_SIZE = 0x20000 };
	uint8_t* pattern = malloc(SAVE_SIZE);
	for (int i = 0; i < SAVE_SIZE; ++i) {
		pattern[i] = (uint8_t) (i * 7);
	}
	FILE* f = fopen(sav, "wb");
	fwrite(pattern, 1, SAVE_SIZE, f);
	fclose(f);

	LRCore* core = lr_create(rom, sav, data, "auto");
	CHECK(core != NULL);
	if (!core) {
		printf("bridge test: %d failures\n", failures + 1);
		return 1;
	}
	CHECK(lr_create(rom, sav, data, "auto") == NULL); /* one core at a time */
	CHECK(lr_audio_rate(core) >= 8000 && lr_frame_rate(core) > 50 && lr_frame_rate(core) < 70);
	for (int i = 0; i < 30; ++i) {
		lr_run_frame(core, false);
	}
	unsigned w = lr_video_width(core), h = lr_video_height(core);
	printf("frame %ux%u, audio %u Hz\n", w, h, lr_audio_rate(core));
	CHECK(w >= 240 && h >= 160 && w <= 1024 && h <= 1024);
	const uint8_t* px = lr_video_buffer(core);
	int red = 0;
	for (unsigned i = 0; i < w * h; ++i) {
		red += px[i * 4] >= 0xF0 && px[i * 4 + 1] < 0x10 && px[i * 4 + 2] < 0x10;
	}
	CHECK(red >= 1); /* the game's red pixel made it, at whatever scale */
	size_t queued = lr_audio_queued(core);
	size_t total = drain(core);
	double expected = lr_audio_rate(core) * 30.0 / lr_frame_rate(core);
	printf("audio: %zu frames for 30 video frames (about %.0f expected)\n", total, expected);
	CHECK(total == queued && total > expected * 0.8 && total < expected * 1.2);
	lr_run_frame(core, true);
	CHECK(drain(core) == 0);

	lr_set_keys(core, LR_KEY_A | LR_KEY_X);
	lr_set_pointer(core, true, 100000, -100000);
	lr_run_frame(core, false);
	lr_set_pointer(core, false, 0, 0);
	lr_set_keys(core, 0);

	CHECK(lr_save_state(core, state));
	CHECK(file_size(state) > 1000);
	lr_run_frame(core, false);
	CHECK(lr_load_state(core, state));
	CHECK(drain(core) == 0);
	CHECK(!lr_load_state(core, "/nonexistent/state"));
	lr_reset(core);
	lr_run_frame(core, false);
	CHECK(lr_flush_save(core));
	lr_destroy(core);
	f = fopen(sav, "rb");
	uint8_t* back = malloc(SAVE_SIZE);
	CHECK(f && fread(back, 1, SAVE_SIZE, f) == SAVE_SIZE && memcmp(back, pattern, SAVE_SIZE) == 0);
	if (f) {
		fclose(f);
	}

	/* Game Boy Color, no save file: none is written for a save the game never touched. */
	core = lr_create(gb, gbsav, data, "auto");
	CHECK(core != NULL);
	if (core) {
		for (int i = 0; i < 10; ++i) {
			lr_run_frame(core, false);
		}
		printf("game boy frame %ux%u\n", lr_video_width(core), lr_video_height(core));
		CHECK(lr_video_width(core) >= 160 && lr_video_height(core) >= 144);
		CHECK(drain(core) > 0);
		lr_destroy(core);
	}
	CHECK(access(gbsav, F_OK) != 0);

	free(back);
	free(pattern);
	printf("bridge test: %d failures\n", failures);
	return failures ? 1 : 0;
}
