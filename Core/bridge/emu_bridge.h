/* emu_bridge: the small C surface the app uses to drive mGBA.
 * Nothing from mGBA leaks through this header, so Swift can import it as is.
 *
 * Threading: every function must be called from the emulation thread, except
 * emu_audio_read (audio thread) and emu_set_keys (any thread).
 *
 * Licensed under the GNU GPL v3 (see LICENSE). mGBA itself is MPL 2.0.
 */
#ifndef EMU_BRIDGE_H
#define EMU_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EMU_VIDEO_WIDTH 240
#define EMU_VIDEO_HEIGHT 160

enum {
	EMU_KEY_A = 1 << 0,
	EMU_KEY_B = 1 << 1,
	EMU_KEY_SELECT = 1 << 2,
	EMU_KEY_START = 1 << 3,
	EMU_KEY_RIGHT = 1 << 4,
	EMU_KEY_LEFT = 1 << 5,
	EMU_KEY_UP = 1 << 6,
	EMU_KEY_DOWN = 1 << 7,
	EMU_KEY_R = 1 << 8,
	EMU_KEY_L = 1 << 9
};

typedef struct EmuCore EmuCore;

/* Loads a GBA ROM. savePath is the battery save (created if missing).
 * Returns NULL when the file is not a usable GBA ROM. */
EmuCore* emu_create(const char* romPath, const char* savePath);
void emu_destroy(EmuCore* emu);

void emu_reset(EmuCore* emu);
/* Runs one video frame and queues the audio it produced. When discardAudio is
 * true (fast-forward), the audio of that frame is dropped. */
void emu_run_frame(EmuCore* emu, bool discardAudio);
void emu_set_keys(EmuCore* emu, uint32_t keys);

/* 240x160 pixels, 4 bytes each in memory order R, G, B, unused. */
const uint8_t* emu_video_buffer(const EmuCore* emu);

unsigned emu_audio_rate(const EmuCore* emu);
/* Copies up to `frames` interleaved stereo frames; returns how many were copied.
 * Safe to call from the audio thread while the emulation thread runs. */
size_t emu_audio_read(EmuCore* emu, int16_t* out, size_t frames);
/* Frames waiting to be played; the frame pacer uses it to stay in step with the speaker. */
size_t emu_audio_queued(const EmuCore* emu);
void emu_audio_clear(EmuCore* emu);

bool emu_save_state(EmuCore* emu, const char* path);
/* Restores a state. The battery save currently in use is kept as it is. */
bool emu_load_state(EmuCore* emu, const char* path);

/* Game memory, by GBA bus address (0x02000000 = work RAM, 0x03000000 = fast RAM...).
 * Return the number of bytes copied. */
size_t emu_read_bytes(EmuCore* emu, uint32_t address, uint8_t* out, size_t length);
size_t emu_write_bytes(EmuCore* emu, uint32_t address, const uint8_t* in, size_t length);

/* ROM header: 4-letter game code (NUL-terminated in out[5]), title, revision. */
void emu_game_code(const EmuCore* emu, char out[5]);
void emu_game_title(const EmuCore* emu, char out[13]);
uint8_t emu_revision(const EmuCore* emu);
const uint8_t* emu_rom_data(const EmuCore* emu, size_t* sizeOut);

#ifdef __cplusplus
}
#endif

#endif
