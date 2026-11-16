/* Smoke test for the mGBA bridge, using a tiny ROM assembled here (no game needed).
 * Build: see scripts/test_bridge.sh
 */
#define _DEFAULT_SOURCE
#include "emu_bridge.h"

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

static void write_test_rom(const char* path) {
	uint8_t rom[0x200];
	memset(rom, 0, sizeof(rom));
	put32(rom, 0xEA00002E); /* b 0x080000C0 */
	memcpy(rom + 0xA0, "CAPSULETEST", 11);
	memcpy(rom + 0xAC, "ZTSE", 4);
	rom[0xB2] = 0x96;
	rom[0xBC] = 3;
	static const uint32_t code[] = {
		0xE3A00301, /* mov  r0, #0x04000000 */
		0xE3A01B01, /* mov  r1, #0x400 */
		0xE2811003, /* add  r1, r1, #3      ; mode 3, BG2 on */
		0xE1C010B0, /* strh r1, [r0] */
		0xE3A02406, /* mov  r2, #0x06000000 */
		0xE3A0301F, /* mov  r3, #0x1F       ; red */
		0xE1C230B0, /* strh r3, [r2]        ; top-left pixel */
		0xE3A04402, /* mov  r4, #0x02000000 */
		0xE3A050AB, /* mov  r5, #0xAB */
		0xE5C45010, /* strb r5, [r4, #0x10] */
		0xE3A05C42, /* mov  r5, #0x4200     ; SOUNDBIAS: resolution 1 (65536 Hz), like Pokemon */
		0xE1C058B8, /* strh r5, [r0, #0x88] */
		0xE5906130, /* ldr  r6, [r0, #0x130] ; KEYINPUT */
		0xE5846030, /* str  r6, [r4, #0x30] */
		0xEAFFFFFC, /* b    back to the ldr */
	};
	for (size_t i = 0; i < sizeof(code) / sizeof(code[0]); ++i) {
		put32(rom + 0xC0 + i * 4, code[i]);
	}
	FILE* f = fopen(path, "wb");
	fwrite(rom, 1, sizeof(rom), f);
	fclose(f);
}

int main(void) {
	char dir[] = "/tmp/capsule-test-XXXXXX";
	if (!mkdtemp(dir)) {
		return 2;
	}
	char rom[256], sav[256], state[256], junk[256];
	snprintf(rom, sizeof(rom), "%s/test.gba", dir);
	snprintf(sav, sizeof(sav), "%s/test.sav", dir);
	snprintf(state, sizeof(state), "%s/test.ss0", dir);
	snprintf(junk, sizeof(junk), "%s/junk.gba", dir);
	write_test_rom(rom);

	/* Not a ROM, and a missing file: both refused cleanly. */
	FILE* f = fopen(junk, "wb");
	for (int i = 0; i < 1024; ++i) {
		fputc(i & 0x7F, f);
	}
	fclose(f);
	CHECK(emu_create(junk, NULL) == NULL);
	CHECK(emu_create("/nonexistent/file.gba", NULL) == NULL);

	EmuCore* emu = emu_create(rom, sav);
	CHECK(emu != NULL);
	if (!emu) {
		return 1;
	}
	char code[5], title[13];
	emu_game_code(emu, code);
	emu_game_title(emu, title);
	CHECK(strcmp(code, "ZTSE") == 0);
	CHECK(strcmp(title, "CAPSULETEST") == 0);
	CHECK(emu_revision(emu) == 3);
	size_t romSize = 0;
	CHECK(emu_rom_data(emu, &romSize) != NULL && romSize == 0x200);
	CHECK(emu_audio_rate(emu) == 48000);
	CHECK(emu_native_audio_rate(emu) == 32768);

	for (int i = 0; i < 10; ++i) {
		emu_run_frame(emu, false);
	}
	printf("native rate after the game set SOUNDBIAS: %u Hz\n", emu_native_audio_rate(emu));
	CHECK(emu_native_audio_rate(emu) == 65536);
		const uint8_t* px = emu_video_buffer(emu);
	printf("pixel0 = %02X %02X %02X %02X, pixel1 = %02X %02X %02X\n", px[0], px[1], px[2], px[3], px[4], px[5], px[6]);
	CHECK(px[0] >= 0xF8 && px[1] == 0 && px[2] == 0); /* red first: R, G, B order */
	CHECK(px[4] == 0 && px[5] == 0 && px[6] == 0);

	uint8_t byte = 0;
	CHECK(emu_read_bytes(emu, 0x02000010, &byte, 1) == 1 && byte == 0xAB);

	int16_t audio[4096 * 2];
	size_t total = 0, got;
	size_t queued = emu_audio_queued(emu);
	CHECK(queued > 0);
	while ((got = emu_audio_read(emu, audio, 4096)) > 0) {
		total += got;
	}
	double expected = emu_audio_rate(emu) * 10.0 / 59.7275;
	printf("audio: %zu frames for 10 video frames (expected about %.0f) at %u Hz\n", total, expected, emu_audio_rate(emu));
	CHECK(total > expected * 0.8 && total < expected * 1.2);
	CHECK(total == queued && emu_audio_queued(emu) == 0);

	/* fast-forward frames drop their audio */
	emu_run_frame(emu, true);
	CHECK(emu_audio_read(emu, audio, 4096) == 0);

	/* memory writes: RAM only */
	uint8_t v = 0x5A;
	CHECK(emu_write_bytes(emu, 0x02000020, &v, 1) == 1);
	CHECK(emu_write_bytes(emu, 0x08000000, &v, 1) == 0);
	CHECK(emu_write_bytes(emu, 0x0E000000, &v, 1) == 0);
	CHECK(emu_read_bytes(emu, 0x02000020, &byte, 1) == 1 && byte == 0x5A);

	/* save state round trip */
	CHECK(emu_save_state(emu, state));
	v = 0x77;
	emu_write_bytes(emu, 0x02000020, &v, 1);
	emu_run_frame(emu, false);
	CHECK(emu_read_bytes(emu, 0x02000020, &byte, 1) == 1 && byte == 0x77);
	CHECK(emu_load_state(emu, state));
	CHECK(emu_read_bytes(emu, 0x02000020, &byte, 1) == 1 && byte == 0x5A);
	CHECK(emu_audio_read(emu, audio, 4096) == 0); /* queue flushed by the load */
	CHECK(!emu_load_state(emu, "/nonexistent/state"));

	emu_set_keys(emu, EMU_KEY_A | EMU_KEY_START);
	emu_run_frame(emu, false);
	uint8_t keyReg[2];
	emu_read_bytes(emu, 0x02000030, keyReg, 2); /* the ROM copies KEYINPUT here; pressed keys read as 0 */
	printf("KEYINPUT = %02X%02X\n", keyReg[1], keyReg[0]);
	CHECK((keyReg[0] & 0x09) == 0 && (keyReg[0] & 0x02) != 0);
	emu_set_keys(emu, 0);
	emu_run_frame(emu, false);
	emu_read_bytes(emu, 0x02000030, keyReg, 2);
	CHECK(keyReg[0] == 0xFF && (keyReg[1] & 0x03) == 0x03);

	emu_reset(emu);
	emu_run_frame(emu, false);
	emu_destroy(emu);
	CHECK(access(sav, F_OK) == 0);

	printf("bridge test: %d failures\n", failures);
	return failures ? 1 : 0;
}
