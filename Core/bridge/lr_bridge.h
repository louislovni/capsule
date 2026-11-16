/* lr_bridge: the app's host for PokeDaisy's libretro cores.
 *
 * PokeDaisy (https://github.com/lidor30/pokedaisy) builds its companion, HUD,
 * quick menu and EXPAND into its libretro core, over mGBA. This bridge owns
 * what a frontend owns: the frame, the sound, the buttons and touch, the
 * battery save and the save states. Nothing from libretro leaks through this
 * header, so Swift imports it as is.
 *
 * libretro is one core per process: create one LRCore at a time.
 * Threading: every function runs on the emulation thread, except
 * lr_audio_read / lr_audio_queued (audio thread) and lr_set_keys /
 * lr_set_pointer (any thread).
 *
 * Licensed under the GNU GPL v3 (see LICENSE).
 */
#ifndef LR_BRIDGE_H
#define LR_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Buttons, as bits of RETRO_DEVICE_ID_JOYPAD_* ids. */
enum {
	LR_KEY_B = 1 << 0,
	LR_KEY_Y = 1 << 1,
	LR_KEY_SELECT = 1 << 2,
	LR_KEY_START = 1 << 3,
	LR_KEY_UP = 1 << 4,
	LR_KEY_DOWN = 1 << 5,
	LR_KEY_LEFT = 1 << 6,
	LR_KEY_RIGHT = 1 << 7,
	LR_KEY_A = 1 << 8,
	LR_KEY_X = 1 << 9,
	LR_KEY_L = 1 << 10,
	LR_KEY_R = 1 << 11,
	LR_KEY_L2 = 1 << 12,
	LR_KEY_R2 = 1 << 13,
	LR_KEY_L3 = 1 << 14,
	LR_KEY_R3 = 1 << 15
};

typedef struct LRCore LRCore;

/* Loads a ROM on the core at corePath (a dynamic library: PokeDaisy's GB / GBA
 * core or its DS core). savePath: the battery save, read now and written by
 * lr_flush_save. dataDir: where the core keeps its own files (companion
 * settings). panel: the screen size hint for the core ("auto", "720x720"...).
 * Returns NULL when the core can't be loaded or refuses the file. */
LRCore* lr_create(const char* corePath, const char* romPath, const char* savePath, const char* dataDir,
                  const char* panel);
/* Why the last lr_create failed, in plain words (empty when it didn't). */
const char* lr_last_error(void);

/* Writes the battery save and unloads. */
void lr_destroy(LRCore* core);

void lr_reset(LRCore* core);
/* One video frame. With discardAudio (fast-forward) its sound is dropped. */
void lr_run_frame(LRCore* core, bool discardAudio);

void lr_set_keys(LRCore* core, uint32_t keys);
/* Touch on the frame, in libretro's -32767..32767 range on both axes. */
void lr_set_pointer(LRCore* core, bool pressed, int x, int y);

/* The last frame: lr_video_width x lr_video_height pixels, 4 bytes each in
 * memory order R, G, B, unused, rows lr_video_width * 4 bytes apart. */
const uint8_t* lr_video_buffer(const LRCore* core);
unsigned lr_video_width(const LRCore* core);
unsigned lr_video_height(const LRCore* core);

unsigned lr_audio_rate(const LRCore* core);
double lr_frame_rate(const LRCore* core);
size_t lr_audio_read(LRCore* core, int16_t* out, size_t frames);
size_t lr_audio_queued(const LRCore* core);

/* Writes the battery save if it changed since the last write. Returns false on a write error. */
bool lr_flush_save(LRCore* core);

bool lr_save_state(LRCore* core, const char* path);
bool lr_load_state(LRCore* core, const char* path);

#ifdef __cplusplus
}
#endif

#endif
