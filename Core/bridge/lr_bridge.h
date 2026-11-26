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
/* A new screen size hint (the phone turned). Call from the thread that runs the
 * frames; a GBA game's canvas follows it within a frame or two. */
void lr_set_panel(LRCore* core, const char* panel);
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

/* Co-op presence (PokeDaisy's GBA core, Emerald in a Western language): the partner's hero on the map. The frontend
 * owns the connection; these run on the emulation thread. nowMs: a monotonic clock in ms (32 bits, wrapping).
 * lr_coop_available: the loaded game can. lr_coop_frame: after each lr_run_frame; true = out holds an update to send.
 * lr_coop_receive: an update the partner sent. lr_coop_stop: the link is gone (nothing drawn, nothing kept). */
#define LR_COOP_PRESENCE_SIZE 20
bool lr_coop_available(const LRCore* core);
bool lr_coop_frame(LRCore* core, uint32_t nowMs, uint8_t out[LR_COOP_PRESENCE_SIZE]);
void lr_coop_receive(LRCore* core, const uint8_t* message, size_t length, uint32_t nowMs);
void lr_coop_stop(LRCore* core);
/* Co-op joined battles (English / French Emerald): the partner's messages in (types 0x0200-0x02FF), the game's out
 * (lr_coop_battle_out until it returns 0; its size, -1 if capacity is too small), and the link's state. On the
 * emulation thread, around lr_run_frame. */
#define LR_COOP_BATTLE_MAX 0x4100
void lr_coop_battle_in(LRCore* core, int type, const uint8_t* bytes, size_t length);
int lr_coop_battle_out(LRCore* core, int* type, uint8_t* out, int capacity);
void lr_coop_battle_link(LRCore* core, bool connected);

/* The companion DOCKED (PokeDaisy's GBA core): its menus (PARTY, DEX, MAP, BAG, GUIDE, SETTINGS) drawn into a canvas of
 * their own for a panel of the frontend's, while the game runs on and shows. All on the emulation thread.
 * lr_dock: the canvas's size in companion pixels (320 x 240 to 640 x 480), 0 x 0 = none. lr_dock_open: opens or closes
 * it (the game's keys are the companion's while open). lr_dock_is_open: it can close itself (B on its first page) and open
 * from the HUD. lr_dock_pixels: 0xRRGGBB, valid until the next frame; serial moves when they're drawn again.
 * lr_dock_touch: the finger, in the canvas's pixels, down while held. */
/* PokeDaisy's companion in this language ("fr"; "en" or NULL = English): its menus, words and guide. */
void lr_set_language(LRCore* core, const char* code);

/* The scene the frontend's weather and light effects follow, after a frame (PokeDaisy's GBA core): [0] the map's weather
 * (the games' WEATHER_*: 3 rain, 4 snow, 5 storm, 6 / 9 fog, 7 ash, 8 sandstorm, 2 / 12 sun, 10 / 14 underwater, 13
 * downpour; -1 unknown), [1] the map type (-1), [2] a battle, [3] the free field on screen, [4] a cave's darkness (0 lit),
 * [5..7] the day and night tint (r, g, b; 256 = day). Returns how many were written (0: no such core). */
#define LR_SCENE_VALUES 10
int lr_scene(const LRCore* core, int32_t* out, int count);

/* The night's lights on the last frame (PokeDaisy's GBA core on the field): each door and window glass as x, y, w, h in
 * the frame's own 0..1 and a kind (0 door, 1 window), 5 floats a light. Returns how many (at most max). */
#define LR_LIGHTS_MAX 32

/* BATTLE SPRITES: the player's Pokémon Black / White (2) cart whose animated pictures replace a GBA battle's (Emerald),
 * or NULL to stop. Emulation thread. */
void lr_battle_sprites(LRCore* core, const char* ndsPath);

/* MÉTÉO DS: the player's HeartGold / SoulSilver cart whose weather sprites replace a GBA game's rain, snow and sand, or NULL.
 * SAISONS: lr_ambience's seasons 0 off, 1 Black / White's, 2 the calendar's. Emulation thread. lr_scene's values 8 / 9 say
 * the core drew the weather / a season's particles that frame. */
void lr_weather_cart(LRCore* core, const char* ndsPath);
void lr_ambience(LRCore* core, bool dsWeather, int seasons);

/* POKÉMON QUI SUIT: the party's lead walks behind the player in a GBA game, drawn from the player's HeartGold /
 * SoulSilver cart's following Pokémon ([ndsPath]), or NULL for none. Emulation thread. */
void lr_follower(LRCore* core, const char* ndsPath);
/* SON EN ACCÉLÉRÉ (Gen 3 games): before each batch of FF frames, whether FF runs ([on]); true when the game can have its
 * music and sounds at 1x through FF. Then, once per frame of real time, lr_ff_audio queues that frame's sound (the FF
 * frames themselves run with discardAudio). Emulation thread. */
bool lr_ff_sound(LRCore* core, bool on);
void lr_ff_audio(LRCore* core);
int lr_lights(const LRCore* core, float* out, int max);

bool lr_dock_available(const LRCore* core);
void lr_dock(LRCore* core, int width, int height);
void lr_dock_open(LRCore* core, bool open);
bool lr_dock_is_open(const LRCore* core);
const uint32_t* lr_dock_pixels(const LRCore* core, int* width, int* height, unsigned* serial);
void lr_dock_touch(LRCore* core, int x, int y, bool down);

#ifdef __cplusplus
}
#endif

#endif
