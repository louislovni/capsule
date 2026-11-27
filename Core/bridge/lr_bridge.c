/* lr_bridge: host for the PokeDaisy libretro core. See lr_bridge.h. GPL v3. */
#include "lr_bridge.h"

#include "libretro.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define RING_FRAMES 16384 /* power of two */
#define RING_MASK (RING_FRAMES - 1)
#define MAX_WIDTH 2048
#define MAX_HEIGHT 2048

struct LRCore {
	uint8_t* rom;
	size_t romSize;
	char* savePath;
	char* dataDir;
	char* panel;
	bool variablesChanged; /* the panel changed: the core reads its options again */
	uint8_t* lastSave; /* what the battery save file holds */
	size_t lastSaveSize;

	enum retro_pixel_format format;
	uint8_t* rgba;
	unsigned width, height;
	unsigned audioRate;
	double fps;
	bool discardAudio;

	atomic_uint keys;
	atomic_int pointerX, pointerY;
	atomic_bool pointerDown;
	/* A tap shorter than a frame (down and up between two polls) still shows as
	 * pressed for one frame, where it went down. */
	atomic_bool pointerLatch;
	atomic_bool pointerPolled; /* the core read the touch during this frame */

	int16_t ring[RING_FRAMES * 2];
	atomic_size_t ringWrite;
	atomic_size_t ringRead;
	atomic_bool ringFlush;
};

/* The core's entry points, looked up by name: each core is its own dynamic
 * library (the two share hundreds of internal names, so they can't be linked
 * into one binary). */
typedef struct {
	void (*set_environment)(retro_environment_t);
	void (*set_video_refresh)(retro_video_refresh_t);
	void (*set_audio_sample)(retro_audio_sample_t);
	void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
	void (*set_input_poll)(retro_input_poll_t);
	void (*set_input_state)(retro_input_state_t);
	void (*init)(void);
	void (*deinit)(void);
	bool (*load_game)(const struct retro_game_info*);
	void (*unload_game)(void);
	void (*run)(void);
	void (*reset)(void);
	void (*get_system_info)(struct retro_system_info*);
	void (*get_system_av_info)(struct retro_system_av_info*);
	void (*set_controller_port_device)(unsigned, unsigned);
	void* (*get_memory_data)(unsigned);
	size_t (*get_memory_size)(unsigned);
	size_t (*serialize_size)(void);
	bool (*serialize)(void*, size_t);
	bool (*unserialize)(const void*, size_t);
	/* Co-op presence (PokeDaisy's GBA core only; NULL elsewhere): see lr_coop_frame. */
	int (*pd_coop_available)(void);
	int (*pd_coop_frame)(uint32_t, uint8_t*);
	void (*pd_coop_receive)(const uint8_t*, size_t, uint32_t);
	void (*pd_coop_stop)(void);
	/* Co-op joined battles (optional: an older core has none). */
	void (*pd_coop_battle_in)(int, const uint8_t*, size_t);
	int (*pd_coop_battle_out)(int*, uint8_t*, int);
	void (*pd_coop_battle_link)(int);
	/* The companion docked in the frontend's panel (PokeDaisy's GBA core only; NULL elsewhere): see lr_dock. */
	void (*pd_dock)(int, int);
	void (*pd_dock_open)(int);
	int (*pd_dock_is_open)(void);
	const uint32_t* (*pd_dock_pixels)(int*, int*, unsigned*);
	void (*pd_dock_touch)(int, int, int);
	void (*pd_language)(const char*); /* PokeDaisy's companion language, NULL elsewhere */
	int (*pd_scene)(int*, int);       /* the weather / light the frontend's effects follow, NULL elsewhere */
	int (*pd_lights)(float*, int);    /* the night's lights (doors, windows) on the field, NULL elsewhere */
	void (*pd_battle_sprites)(const char*); /* BATTLE SPRITES' DS cart, NULL elsewhere */
	void (*pd_weather_cart)(const char*);   /* MÉTÉO DS's HeartGold / SoulSilver cart, NULL elsewhere */
	void (*pd_ambience)(int, int);          /* MÉTÉO DS / SAISONS on or off, NULL elsewhere */
	void (*pd_follower)(const char*);       /* POKÉMON QUI SUIT's HeartGold / SoulSilver cart, NULL elsewhere */
	void (*pd_dynamic_weather)(int);        /* MÉTÉO DYNAMIQUE */
	bool (*pd_ff_sound)(bool);              /* SON EN ACCÉLÉRÉ: FF running; whether the game can have it */
	int (*pd_ff_audio)(int16_t*, int);      /* ... one frame of real time's music and sounds */
} RetroAPI;

static RetroAPI api;

static char sError[512];

static void set_error(const char* format, ...) {
	va_list args;
	va_start(args, format);
	vsnprintf(sError, sizeof(sError), format, args);
	va_end(args);
	fprintf(stderr, "lr_bridge: %s\n", sError);
}

const char* lr_last_error(void) {
	return sError;
}

/* Libraries stay loaded once opened: a core is not written to be unloaded. */
#define MAX_LIBRARIES 4
static struct {
	char* path;
	void* handle;
} sLibraries[MAX_LIBRARIES];

static void* open_library(const char* path) {
	for (int i = 0; i < MAX_LIBRARIES; ++i) {
		if (sLibraries[i].path && strcmp(sLibraries[i].path, path) == 0) {
			return sLibraries[i].handle;
		}
	}
	FILE* probe = fopen(path, "rb");
	if (!probe) {
		set_error("core not found: %s", path);
		return NULL;
	}
	fclose(probe);
	void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!handle) {
		const char* why = dlerror();
		set_error("dlopen failed: %s", why ? why : "unknown");
		return NULL;
	}
	for (int i = 0; i < MAX_LIBRARIES; ++i) {
		if (!sLibraries[i].path) {
			size_t length = strlen(path) + 1;
			sLibraries[i].path = malloc(length);
			if (sLibraries[i].path) {
				memcpy(sLibraries[i].path, path, length);
				sLibraries[i].handle = handle;
			}
			break;
		}
	}
	return handle;
}

static bool load_api(const char* corePath) {
	void* h = open_library(corePath);
	if (!h) {
		return false;
	}
	RetroAPI loaded;
#define LOOKUP(name) \
	if (!(*(void**) &loaded.name = dlsym(h, "retro_" #name))) { \
		set_error("retro_%s missing from the core", #name); \
		return false; \
	}
	LOOKUP(set_environment)
	LOOKUP(set_video_refresh)
	LOOKUP(set_audio_sample)
	LOOKUP(set_audio_sample_batch)
	LOOKUP(set_input_poll)
	LOOKUP(set_input_state)
	LOOKUP(init)
	LOOKUP(deinit)
	LOOKUP(load_game)
	LOOKUP(unload_game)
	LOOKUP(run)
	LOOKUP(reset)
	LOOKUP(get_system_info)
	LOOKUP(get_system_av_info)
	LOOKUP(set_controller_port_device)
	LOOKUP(get_memory_data)
	LOOKUP(get_memory_size)
	LOOKUP(serialize_size)
	LOOKUP(serialize)
	LOOKUP(unserialize)
#undef LOOKUP
	*(void**) &loaded.pd_language = dlsym(h, "retro_pd_language");
	*(void**) &loaded.pd_scene = dlsym(h, "retro_pd_scene");
	*(void**) &loaded.pd_lights = dlsym(h, "retro_pd_lights");
	*(void**) &loaded.pd_battle_sprites = dlsym(h, "retro_pd_battle_sprites");
	*(void**) &loaded.pd_weather_cart = dlsym(h, "retro_pd_weather_cart");
	*(void**) &loaded.pd_ambience = dlsym(h, "retro_pd_ambience");
	*(void**) &loaded.pd_follower = dlsym(h, "retro_pd_follower");
	*(void**) &loaded.pd_dynamic_weather = dlsym(h, "retro_pd_dynamic_weather");
	*(void**) &loaded.pd_ff_sound = dlsym(h, "retro_pd_ff_sound");
	*(void**) &loaded.pd_ff_audio = dlsym(h, "retro_pd_ff_audio");
	*(void**) &loaded.pd_dock = dlsym(h, "retro_pd_dock");
	*(void**) &loaded.pd_dock_open = dlsym(h, "retro_pd_dock_open");
	*(void**) &loaded.pd_dock_is_open = dlsym(h, "retro_pd_dock_is_open");
	*(void**) &loaded.pd_dock_pixels = dlsym(h, "retro_pd_dock_pixels");
	*(void**) &loaded.pd_dock_touch = dlsym(h, "retro_pd_dock_touch");
	if (!loaded.pd_dock || !loaded.pd_dock_open || !loaded.pd_dock_is_open || !loaded.pd_dock_pixels || !loaded.pd_dock_touch) {
		loaded.pd_dock = NULL;
		loaded.pd_dock_open = NULL;
		loaded.pd_dock_is_open = NULL;
		loaded.pd_dock_pixels = NULL;
		loaded.pd_dock_touch = NULL;
	}
	*(void**) &loaded.pd_coop_available = dlsym(h, "retro_pd_coop_available");
	*(void**) &loaded.pd_coop_frame = dlsym(h, "retro_pd_coop_frame");
	*(void**) &loaded.pd_coop_receive = dlsym(h, "retro_pd_coop_receive");
	*(void**) &loaded.pd_coop_stop = dlsym(h, "retro_pd_coop_stop");
	*(void**) &loaded.pd_coop_battle_in = dlsym(h, "retro_pd_coop_battle_in");
	*(void**) &loaded.pd_coop_battle_out = dlsym(h, "retro_pd_coop_battle_out");
	*(void**) &loaded.pd_coop_battle_link = dlsym(h, "retro_pd_coop_battle_link");
	if (!loaded.pd_coop_battle_in || !loaded.pd_coop_battle_out || !loaded.pd_coop_battle_link) {
		loaded.pd_coop_battle_in = NULL;
		loaded.pd_coop_battle_out = NULL;
		loaded.pd_coop_battle_link = NULL;
	}
	if (!loaded.pd_coop_available || !loaded.pd_coop_frame || !loaded.pd_coop_receive || !loaded.pd_coop_stop) {
		loaded.pd_coop_available = NULL;
		loaded.pd_coop_frame = NULL;
		loaded.pd_coop_receive = NULL;
		loaded.pd_coop_stop = NULL;
	}
	api = loaded;
	return true;
}

/* libretro hands callbacks no context: one core per process. */
static LRCore* sCore;

static void core_log(enum retro_log_level level, const char* fmt, ...) {
	if (level < RETRO_LOG_INFO) {
		return;
	}
	va_list args;
	va_start(args, fmt);
	vfprintf(stderr, fmt, args);
	va_end(args);
}

static bool environment(unsigned cmd, void* data) {
	LRCore* core = sCore;
	switch (cmd) {
	case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
		enum retro_pixel_format format = *(const enum retro_pixel_format*) data;
		if (format != RETRO_PIXEL_FORMAT_RGB565 && format != RETRO_PIXEL_FORMAT_XRGB8888 &&
		    format != RETRO_PIXEL_FORMAT_0RGB1555) {
			return false;
		}
		if (core) {
			core->format = format;
		}
		return true;
	}
	case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
	case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
		*(const char**) data = core ? core->dataDir : NULL;
		return core != NULL;
	case RETRO_ENVIRONMENT_GET_CAN_DUPE:
		*(bool*) data = true;
		return true;
	case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
		return true;
	case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
		((struct retro_log_callback*) data)->log = core_log;
		return true;
	case RETRO_ENVIRONMENT_GET_VARIABLE: {
		struct retro_variable* variable = data;
		if (core && variable->key && strcmp(variable->key, "pokedaisy_panel") == 0 && core->panel) {
			variable->value = core->panel;
			return true;
		}
		variable->value = NULL;
		return false;
	}
	case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
		*(bool*) data = core && core->variablesChanged;
		if (core) {
			core->variablesChanged = false;
		}
		return true;
	case RETRO_ENVIRONMENT_SET_GEOMETRY:
	case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
	case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
	case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
	case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
	case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
		return true;
	default:
		return false;
	}
}

static void video_refresh(const void* data, unsigned width, unsigned height, size_t pitch) {
	LRCore* core = sCore;
	if (!core || !data || width == 0 || height == 0) {
		return; /* a duplicate frame: keep the last one */
	}
	if (width > MAX_WIDTH) {
		width = MAX_WIDTH;
	}
	if (height > MAX_HEIGHT) {
		height = MAX_HEIGHT;
	}
	uint8_t* out = core->rgba;
	for (unsigned y = 0; y < height; ++y) {
		const uint8_t* row = (const uint8_t*) data + (size_t) y * pitch;
		uint8_t* dest = out + (size_t) y * width * 4;
		if (core->format == RETRO_PIXEL_FORMAT_XRGB8888) {
			const uint32_t* src = (const uint32_t*) row;
			for (unsigned x = 0; x < width; ++x) {
				uint32_t p = src[x];
				dest[x * 4] = (uint8_t) (p >> 16);
				dest[x * 4 + 1] = (uint8_t) (p >> 8);
				dest[x * 4 + 2] = (uint8_t) p;
				dest[x * 4 + 3] = 0xFF;
			}
		} else if (core->format == RETRO_PIXEL_FORMAT_RGB565) {
			const uint16_t* src = (const uint16_t*) row;
			for (unsigned x = 0; x < width; ++x) {
				uint16_t p = src[x];
				uint8_t r = (p >> 11) & 0x1F, g = (p >> 5) & 0x3F, b = p & 0x1F;
				dest[x * 4] = (uint8_t) ((r << 3) | (r >> 2));
				dest[x * 4 + 1] = (uint8_t) ((g << 2) | (g >> 4));
				dest[x * 4 + 2] = (uint8_t) ((b << 3) | (b >> 2));
				dest[x * 4 + 3] = 0xFF;
			}
		} else {
			const uint16_t* src = (const uint16_t*) row;
			for (unsigned x = 0; x < width; ++x) {
				uint16_t p = src[x];
				uint8_t r = (p >> 10) & 0x1F, g = (p >> 5) & 0x1F, b = p & 0x1F;
				dest[x * 4] = (uint8_t) ((r << 3) | (r >> 2));
				dest[x * 4 + 1] = (uint8_t) ((g << 3) | (g >> 2));
				dest[x * 4 + 2] = (uint8_t) ((b << 3) | (b >> 2));
				dest[x * 4 + 3] = 0xFF;
			}
		}
	}
	core->width = width;
	core->height = height;
}

static void ring_push(LRCore* core, const int16_t* data, size_t frames);

static size_t audio_batch(const int16_t* data, size_t frames) {
	LRCore* core = sCore;
	if (!core || !data || core->discardAudio) {
		return frames;
	}
	ring_push(core, data, frames);
	return frames;
}

static void ring_push(LRCore* core, const int16_t* data, size_t frames) {
	size_t write = atomic_load_explicit(&core->ringWrite, memory_order_relaxed);
	size_t read = atomic_load_explicit(&core->ringRead, memory_order_acquire);
	size_t space = RING_FRAMES - (write - read);
	size_t count = frames < space ? frames : space; /* the player is behind: drop the rest */
	for (size_t i = 0; i < count; ++i) {
		size_t at = (write + i) & RING_MASK;
		core->ring[at * 2] = data[i * 2];
		core->ring[at * 2 + 1] = data[i * 2 + 1];
	}
	atomic_store_explicit(&core->ringWrite, write + count, memory_order_release);
}

static void audio_sample(int16_t left, int16_t right) {
	int16_t frame[2] = { left, right };
	audio_batch(frame, 1);
}

static void input_poll(void) {
}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
	LRCore* core = sCore;
	(void) index;
	if (!core || port != 0) {
		return 0;
	}
	if (device == RETRO_DEVICE_JOYPAD) {
		unsigned keys = atomic_load_explicit(&core->keys, memory_order_relaxed);
		if (id == RETRO_DEVICE_ID_JOYPAD_MASK) {
			return (int16_t) (keys & 0xFFFF);
		}
		return id < 16 ? (int16_t) ((keys >> id) & 1) : 0;
	}
	if (device == RETRO_DEVICE_POINTER) {
		switch (id) {
		case RETRO_DEVICE_ID_POINTER_X: return (int16_t) atomic_load(&core->pointerX);
		case RETRO_DEVICE_ID_POINTER_Y: return (int16_t) atomic_load(&core->pointerY);
		case RETRO_DEVICE_ID_POINTER_PRESSED:
		case RETRO_DEVICE_ID_POINTER_COUNT:
			atomic_store(&core->pointerPolled, true);
			return atomic_load(&core->pointerDown) || atomic_load(&core->pointerLatch) ? 1 : 0;
		default: return 0;
		}
	}
	return 0;
}

static uint8_t* read_file(const char* path, size_t* sizeOut, size_t maxSize) {
	*sizeOut = 0;
	FILE* f = path ? fopen(path, "rb") : NULL;
	if (!f) {
		return NULL;
	}
	uint8_t* data = NULL;
	if (fseek(f, 0, SEEK_END) == 0) {
		long size = ftell(f);
		if (size > 0 && (size_t) size <= maxSize && fseek(f, 0, SEEK_SET) == 0) {
			data = malloc((size_t) size);
			if (data && fread(data, 1, (size_t) size, f) == (size_t) size) {
				*sizeOut = (size_t) size;
			} else {
				free(data);
				data = NULL;
			}
		}
	}
	fclose(f);
	return data;
}

static bool write_file_atomically(const char* path, const uint8_t* data, size_t size) {
	size_t length = strlen(path);
	char* temporary = malloc(length + 5);
	if (!temporary) {
		return false;
	}
	memcpy(temporary, path, length);
	memcpy(temporary + length, ".tmp", 5);
	FILE* f = fopen(temporary, "wb");
	bool ok = f && fwrite(data, 1, size, f) == size;
	if (f) {
		ok = fclose(f) == 0 && ok;
	}
	ok = ok && rename(temporary, path) == 0;
	if (!ok) {
		remove(temporary);
	}
	free(temporary);
	return ok;
}

static char* copy_string(const char* text) {
	if (!text) {
		return NULL;
	}
	size_t length = strlen(text) + 1;
	char* copy = malloc(length);
	if (copy) {
		memcpy(copy, text, length);
	}
	return copy;
}

static void free_core(LRCore* core) {
	if (!core) {
		return;
	}
	free(core->rom);
	free(core->savePath);
	free(core->dataDir);
	free(core->panel);
	free(core->lastSave);
	free(core->rgba);
	free(core);
}

void lr_set_panel(LRCore* core, const char* panel) {
	if (!core || !panel || (core->panel && strcmp(core->panel, panel) == 0)) {
		return;
	}
	char* copy = copy_string(panel);
	if (!copy) {
		return;
	}
	free(core->panel);
	core->panel = copy;
	core->variablesChanged = true;
}

LRCore* lr_create(const char* corePath, const char* romPath, const char* savePath, const char* dataDir,
                  const char* panel) {
	sError[0] = '\0';
	if (sCore) {
		set_error("a game is already running");
		return NULL;
	}
	if (!romPath || !corePath || !load_api(corePath)) {
		if (!sError[0]) {
			set_error("no core or ROM given");
		}
		return NULL;
	}
	LRCore* core = calloc(1, sizeof(*core));
	if (!core) {
		return NULL;
	}
	core->format = RETRO_PIXEL_FORMAT_0RGB1555;
	/* A core that maps the file itself (the DS one: carts run to 512 MB) gets
	 * only its path; the others get its bytes. */
	struct retro_system_info system;
	memset(&system, 0, sizeof(system));
	api.get_system_info(&system);
	bool wantsPath = system.need_fullpath;
	if (wantsPath) {
		struct stat st;
		if (stat(romPath, &st) == 0 && st.st_size > 0) {
			core->romSize = (size_t) st.st_size;
			core->rom = malloc(1); /* a placeholder: nothing is read */
		}
	} else {
		core->rom = read_file(romPath, &core->romSize, 0x4000000);
	}
	core->savePath = copy_string(savePath);
	core->dataDir = copy_string(dataDir ? dataDir : ".");
	core->panel = copy_string(panel);
	core->rgba = calloc((size_t) MAX_WIDTH * MAX_HEIGHT, 4);
	if (!core->rom || !core->rgba || !core->dataDir) {
		set_error(core->rom ? "out of memory" : "could not read the ROM file (%s)", romPath);
		free_core(core);
		return NULL;
	}
	if (dataDir) {
		mkdir(dataDir, 0755);
	}

	sCore = core;
	api.set_environment(environment);
	api.set_video_refresh(video_refresh);
	api.set_audio_sample(audio_sample);
	api.set_audio_sample_batch(audio_batch);
	api.set_input_poll(input_poll);
	api.set_input_state(input_state);
	api.init();

	struct retro_game_info info = { romPath, wantsPath ? NULL : core->rom, wantsPath ? 0 : core->romSize, NULL };
	if (!api.load_game(&info)) {
		set_error("the core refused the ROM (%zu bytes)", core->romSize);
		api.deinit();
		sCore = NULL;
		free_core(core);
		return NULL;
	}
	api.set_controller_port_device(0, RETRO_DEVICE_JOYPAD);

	struct retro_system_av_info av;
	memset(&av, 0, sizeof(av));
	api.get_system_av_info(&av);
	core->audioRate = av.timing.sample_rate > 0 ? (unsigned) (av.timing.sample_rate + 0.5) : 32768;
	core->fps = av.timing.fps > 0 ? av.timing.fps : 59.7275;
	core->width = av.geometry.base_width;
	core->height = av.geometry.base_height;

	/* The battery save goes into the core's memory now, before the first frame. */
	uint8_t* sram = api.get_memory_data(RETRO_MEMORY_SAVE_RAM);
	size_t sramSize = api.get_memory_size(RETRO_MEMORY_SAVE_RAM);
	if (sram && sramSize) {
		size_t fileSize = 0;
		uint8_t* saved = read_file(core->savePath, &fileSize, 0x200000);
		if (saved) {
			memcpy(sram, saved, fileSize < sramSize ? fileSize : sramSize);
			core->lastSave = saved;
			core->lastSaveSize = fileSize;
		}
	}
	return core;
}

void lr_destroy(LRCore* core) {
	if (!core || core != sCore) {
		return;
	}
	lr_flush_save(core);
	api.unload_game();
	api.deinit();
	sCore = NULL;
	free_core(core);
}

void lr_reset(LRCore* core) {
	if (core && core == sCore) {
		api.reset();
		atomic_store(&core->ringFlush, true);
	}
}

void lr_run_frame(LRCore* core, bool discardAudio) {
	if (!core || core != sCore) {
		return;
	}
	core->discardAudio = discardAudio;
	api.run();
	core->discardAudio = false;
	if (atomic_exchange(&core->pointerPolled, false)) {
		atomic_store(&core->pointerLatch, false);
	}
}

void lr_set_keys(LRCore* core, uint32_t keys) {
	if (core) {
		atomic_store_explicit(&core->keys, keys, memory_order_relaxed);
	}
}

void lr_set_pointer(LRCore* core, bool pressed, int x, int y) {
	if (!core) {
		return;
	}
	if (x < -0x7FFF) {
		x = -0x7FFF;
	}
	if (x > 0x7FFF) {
		x = 0x7FFF;
	}
	if (y < -0x7FFF) {
		y = -0x7FFF;
	}
	if (y > 0x7FFF) {
		y = 0x7FFF;
	}
	if (!pressed) {
		/* Lifted: the last place stays, for a tap the core has not seen yet. */
		atomic_store(&core->pointerDown, false);
		return;
	}
	atomic_store(&core->pointerX, x);
	atomic_store(&core->pointerY, y);
	atomic_store(&core->pointerLatch, true);
	atomic_store(&core->pointerDown, true);
}

const uint8_t* lr_video_buffer(const LRCore* core) {
	return core ? core->rgba : NULL;
}

unsigned lr_video_width(const LRCore* core) {
	return core ? core->width : 0;
}

unsigned lr_video_height(const LRCore* core) {
	return core ? core->height : 0;
}

unsigned lr_audio_rate(const LRCore* core) {
	return core ? core->audioRate : 32768;
}

double lr_frame_rate(const LRCore* core) {
	return core ? core->fps : 59.7275;
}

size_t lr_audio_read(LRCore* core, int16_t* out, size_t frames) {
	if (!core || !out) {
		return 0;
	}
	size_t read = atomic_load_explicit(&core->ringRead, memory_order_relaxed);
	size_t write = atomic_load_explicit(&core->ringWrite, memory_order_acquire);
	if (atomic_exchange(&core->ringFlush, false)) {
		atomic_store_explicit(&core->ringRead, write, memory_order_release);
		return 0;
	}
	size_t available = write - read;
	if (frames > available) {
		frames = available;
	}
	for (size_t i = 0; i < frames; ++i) {
		size_t at = (read + i) & RING_MASK;
		out[i * 2] = core->ring[at * 2];
		out[i * 2 + 1] = core->ring[at * 2 + 1];
	}
	atomic_store_explicit(&core->ringRead, read + frames, memory_order_release);
	return frames;
}

size_t lr_audio_queued(const LRCore* core) {
	if (!core) {
		return 0;
	}
	size_t write = atomic_load_explicit(&((LRCore*) core)->ringWrite, memory_order_acquire);
	size_t read = atomic_load_explicit(&((LRCore*) core)->ringRead, memory_order_acquire);
	return write - read;
}

bool lr_flush_save(LRCore* core) {
	if (!core || core != sCore || !core->savePath) {
		return false;
	}
	uint8_t* sram = api.get_memory_data(RETRO_MEMORY_SAVE_RAM);
	size_t size = api.get_memory_size(RETRO_MEMORY_SAVE_RAM);
	if (!sram || size == 0) {
		return true; /* the cartridge has no battery save */
	}
	if (core->lastSave && core->lastSaveSize == size && memcmp(core->lastSave, sram, size) == 0) {
		return true;
	}
	if (!core->lastSave) {
		/* Never write a save the game has not touched: all 0x00 or all 0xFF. */
		bool blank = true;
		for (size_t i = 1; i < size && blank; ++i) {
			blank = sram[i] == sram[0];
		}
		if (blank && (sram[0] == 0x00 || sram[0] == 0xFF)) {
			return true;
		}
	}
	if (!write_file_atomically(core->savePath, sram, size)) {
		return false;
	}
	uint8_t* copy = realloc(core->lastSave, size);
	if (copy) {
		memcpy(copy, sram, size);
		core->lastSave = copy;
		core->lastSaveSize = size;
	}
	return true;
}

bool lr_save_state(LRCore* core, const char* path) {
	if (!core || core != sCore || !path) {
		return false;
	}
	size_t size = api.serialize_size();
	uint8_t* data = size ? malloc(size) : NULL;
	bool ok = data && api.serialize(data, size) && write_file_atomically(path, data, size);
	free(data);
	return ok;
}

bool lr_load_state(LRCore* core, const char* path) {
	if (!core || core != sCore || !path) {
		return false;
	}
	/* The battery save in memory must survive a state load, or the PC
	 * would go back to what it held when the state was made. */
	uint8_t* sram = api.get_memory_data(RETRO_MEMORY_SAVE_RAM);
	size_t sramSize = api.get_memory_size(RETRO_MEMORY_SAVE_RAM);
	uint8_t* keep = sram && sramSize ? malloc(sramSize) : NULL;
	if (keep) {
		memcpy(keep, sram, sramSize);
	}
	size_t size = 0;
	uint8_t* data = read_file(path, &size, 0x4000000);
	bool ok = data && api.unserialize(data, size);
	free(data);
	if (keep) {
		uint8_t* now = api.get_memory_data(RETRO_MEMORY_SAVE_RAM);
		if (now && api.get_memory_size(RETRO_MEMORY_SAVE_RAM) == sramSize) {
			memcpy(now, keep, sramSize);
		}
		free(keep);
	}
	atomic_store(&core->ringFlush, true);
	return ok;
}

bool lr_coop_available(const LRCore* core) {
	return core && api.pd_coop_available && api.pd_coop_available() != 0;
}

bool lr_coop_frame(LRCore* core, uint32_t nowMs, uint8_t out[LR_COOP_PRESENCE_SIZE]) {
	return core && api.pd_coop_frame && api.pd_coop_frame(nowMs, out) != 0;
}

void lr_coop_receive(LRCore* core, const uint8_t* message, size_t length, uint32_t nowMs) {
	if (core && api.pd_coop_receive) {
		api.pd_coop_receive(message, length, nowMs);
	}
}

void lr_coop_battle_in(LRCore* core, int type, const uint8_t* bytes, size_t length) {
	if (core && api.pd_coop_battle_in) {
		api.pd_coop_battle_in(type, bytes, length);
	}
}

int lr_coop_battle_out(LRCore* core, int* type, uint8_t* out, int capacity) {
	return core && api.pd_coop_battle_out ? api.pd_coop_battle_out(type, out, capacity) : 0;
}

void lr_coop_battle_link(LRCore* core, bool connected) {
	if (core && api.pd_coop_battle_link) {
		api.pd_coop_battle_link(connected ? 1 : 0);
	}
}

void lr_coop_stop(LRCore* core) {
	if (core && api.pd_coop_stop) {
		api.pd_coop_stop();
	}
}

bool lr_dock_available(const LRCore* core) {
	return core && api.pd_dock != NULL;
}

void lr_dock(LRCore* core, int width, int height) {
	if (core && api.pd_dock) {
		api.pd_dock(width, height);
	}
}

void lr_dock_open(LRCore* core, bool open) {
	if (core && api.pd_dock_open) {
		api.pd_dock_open(open ? 1 : 0);
	}
}

bool lr_dock_is_open(const LRCore* core) {
	return core && api.pd_dock_is_open && api.pd_dock_is_open() != 0;
}

const uint32_t* lr_dock_pixels(const LRCore* core, int* width, int* height, unsigned* serial) {
	if (!core || !api.pd_dock_pixels) {
		return NULL;
	}
	return api.pd_dock_pixels(width, height, serial);
}

void lr_dock_touch(LRCore* core, int x, int y, bool down) {
	if (core && api.pd_dock_touch) {
		api.pd_dock_touch(x, y, down ? 1 : 0);
	}
}

void lr_set_language(LRCore* core, const char* code) {
	if (core && api.pd_language) {
		api.pd_language(code);
	}
}

int lr_scene(const LRCore* core, int32_t* out, int count) {
	if (!core || !api.pd_scene || count <= 0) {
		return 0;
	}
	int values[LR_SCENE_VALUES];
	int n = api.pd_scene(values, count < LR_SCENE_VALUES ? count : LR_SCENE_VALUES);
	for (int i = 0; i < n; i++) {
		out[i] = values[i];
	}
	return n;
}

int lr_lights(const LRCore* core, float* out, int max) {
	if (!core || !api.pd_lights || max <= 0) {
		return 0;
	}
	return api.pd_lights(out, max < LR_LIGHTS_MAX ? max : LR_LIGHTS_MAX);
}

void lr_battle_sprites(LRCore* core, const char* ndsPath) {
	if (core && api.pd_battle_sprites) {
		api.pd_battle_sprites(ndsPath);
	}
}

void lr_weather_cart(LRCore* core, const char* ndsPath) {
	if (core && api.pd_weather_cart) {
		api.pd_weather_cart(ndsPath);
	}
}

void lr_ambience(LRCore* core, bool dsWeather, int seasons) {
	if (core && api.pd_ambience) {
		api.pd_ambience(dsWeather ? 1 : 0, seasons);
	}
}

void lr_dynamic_weather(LRCore* core, bool on) {
	if (core && api.pd_dynamic_weather) {
		api.pd_dynamic_weather(on ? 1 : 0);
	}
}

void lr_follower(LRCore* core, const char* ndsPath) {
	if (core && api.pd_follower) {
		api.pd_follower(ndsPath);
	}
}

bool lr_ff_sound(LRCore* core, bool on) {
	return core && api.pd_ff_sound && api.pd_ff_sound(on);
}

void lr_ff_audio(LRCore* core) {
	if (!core || !api.pd_ff_audio) {
		return;
	}
	int16_t frame[2048 * 2];
	int n = api.pd_ff_audio(frame, 2048);
	if (n > 0) {
		ring_push(core, frame, (size_t) n);
	}
}
