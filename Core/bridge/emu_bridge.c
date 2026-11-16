/* emu_bridge: mGBA wrapper. See emu_bridge.h. GPL v3; mGBA is MPL 2.0. */
#include "emu_bridge.h"

/* mGBA's structures depend on its build switches (ENABLE_VFS, ENABLE_DIRECTORIES...).
 * Core/CMakeLists.txt compiles this file with the same definitions as mGBA;
 * building it any other way gives mismatched layouts and crashes. */
#include <mgba/core/config.h>
#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba/core/serialize.h>
#include <mgba/gba/core.h>
#include <mgba-util/audio-buffer.h>
#include <mgba-util/audio-resampler.h>
#include <mgba-util/vfs.h>

#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The GBA's own sample rate changes while a game runs (32768 to 262144 Hz,
 * set by the game through SOUNDBIAS; Pokemon switches to 65536 Hz once its
 * sound engine starts). Everything is resampled to this fixed rate, so the
 * app never has to follow those changes. */
#define OUTPUT_RATE 48000
/* About 0.34 s of stereo audio at 48 kHz. Must be a power of two. */
#define RING_FRAMES 16384
#define RING_MASK (RING_FRAMES - 1)
#define AUDIO_CHUNK 2048
/* Room for one video frame of samples at the highest GBA rate (about 4400). */
#define CORE_AUDIO_FRAMES 8192

struct EmuCore {
	struct mCore* core;
	uint8_t* rom;
	size_t romSize;
	mColor* video;
	atomic_uint keys;
	struct mAudioResampler resampler;
	struct mAudioBuffer resampled;
	bool audioReady;

	/* Single producer (emulation thread), single consumer (audio thread). */
	int16_t ring[RING_FRAMES * 2];
	atomic_size_t ringWrite;
	atomic_size_t ringRead;
	atomic_bool ringFlush; /* asks the reader to drop what is queued */
	int16_t scratch[AUDIO_CHUNK * 2];
};

static void quiet_log(struct mLogger* logger, int category, enum mLogLevel level, const char* format, va_list args) {
	(void) logger;
	(void) category;
	if (level & (mLOG_FATAL | mLOG_ERROR)) {
		vfprintf(stderr, format, args);
		fputc('\n', stderr);
	}
}

static struct mLogger sLogger = { .log = quiet_log, .filter = NULL };

static uint8_t* read_file(const char* path, size_t* sizeOut) {
	FILE* f = fopen(path, "rb");
	if (!f) {
		return NULL;
	}
	uint8_t* data = NULL;
	if (fseek(f, 0, SEEK_END) == 0) {
		long size = ftell(f);
		/* GBA cartridges are at most 32 MB. */
		if (size >= 0xC0 && size <= 0x2000000 && fseek(f, 0, SEEK_SET) == 0) {
			data = malloc((size_t) size);
			if (data && fread(data, 1, (size_t) size, f) != (size_t) size) {
				free(data);
				data = NULL;
			}
			*sizeOut = (size_t) size;
		}
	}
	fclose(f);
	return data;
}

EmuCore* emu_create(const char* romPath, const char* savePath) {
	if (!romPath) {
		return NULL;
	}
	mLogSetDefaultLogger(&sLogger);

	EmuCore* emu = calloc(1, sizeof(*emu));
	if (!emu) {
		return NULL;
	}
	emu->rom = read_file(romPath, &emu->romSize);
	emu->video = calloc(EMU_VIDEO_WIDTH * EMU_VIDEO_HEIGHT, sizeof(mColor));
	if (!emu->rom || !emu->video) {
		emu_destroy(emu);
		return NULL;
	}

	struct VFile* romFile = VFileFromConstMemory(emu->rom, emu->romSize);
	struct mCore* core = GBACoreCreate();
	if (!romFile || !core || !core->isROM(romFile)) {
		if (romFile) {
			romFile->close(romFile);
		}
		if (core) {
			/* never initialised: plain free matches what deinit would do last */
			free(core);
		}
		emu_destroy(emu);
		return NULL;
	}

	mCoreInitConfig(core, NULL);
	if (!core->init(core)) {
		romFile->close(romFile);
		mCoreConfigDeinit(&core->config);
		free(core);
		emu_destroy(emu);
		return NULL;
	}
	emu->core = core;

	struct mCoreOptions opts = {
		.useBios = false, /* built-in high-level BIOS: no BIOS file needed */
		.skipBios = true,
		.volume = 0x100,
	};
	mCoreConfigSetDefaultValue(&core->config, "idleOptimization", "detect");
	mCoreConfigLoadDefaults(&core->config, &opts);
	mCoreLoadForeignConfig(core, &core->config);

	core->setVideoBuffer(core, emu->video, EMU_VIDEO_WIDTH);
	core->setAudioBufferSize(core, CORE_AUDIO_FRAMES);

	if (!core->loadROM(core, romFile)) {
		romFile->close(romFile);
		emu_destroy(emu);
		return NULL;
	}
	if (savePath) {
		struct VFile* save = VFileOpen(savePath, O_CREAT | O_RDWR);
		if (save) {
			core->loadSave(core, save);
		}
	}
	core->reset(core);

	mAudioBufferInit(&emu->resampled, CORE_AUDIO_FRAMES, 2);
	mAudioResamplerInit(&emu->resampler, mINTERPOLATOR_SINC);
	mAudioResamplerSetDestination(&emu->resampler, &emu->resampled, OUTPUT_RATE);
	emu->audioReady = true;
	return emu;
}

void emu_destroy(EmuCore* emu) {
	if (!emu) {
		return;
	}
	if (emu->core) {
		struct mCore* core = emu->core;
		core->unloadROM(core); /* flushes and closes the battery save */
		mCoreConfigDeinit(&core->config);
		core->deinit(core);
	}
	if (emu->audioReady) {
		mAudioResamplerDeinit(&emu->resampler);
		mAudioBufferDeinit(&emu->resampled);
	}
	free(emu->video);
	free(emu->rom);
	free(emu);
}

void emu_reset(EmuCore* emu) {
	if (emu && emu->core) {
		emu->core->reset(emu->core);
		emu_audio_clear(emu);
	}
}

static void pump_audio(EmuCore* emu, bool discard) {
	struct mCore* core = emu->core;
	/* Read the rate every frame: the game may have just changed it. */
	mAudioResamplerSetSource(&emu->resampler, core->getAudioBuffer(core), core->audioSampleRate(core), true);
	mAudioResamplerProcess(&emu->resampler);

	struct mAudioBuffer* buffer = &emu->resampled;
	size_t available;
	while ((available = mAudioBufferAvailable(buffer)) > 0) {
		if (available > AUDIO_CHUNK) {
			available = AUDIO_CHUNK;
		}
		size_t got = mAudioBufferRead(buffer, emu->scratch, available);
		if (got == 0) {
			break;
		}
		if (discard) {
			continue;
		}
		size_t write = atomic_load_explicit(&emu->ringWrite, memory_order_relaxed);
		size_t read = atomic_load_explicit(&emu->ringRead, memory_order_acquire);
		size_t space = RING_FRAMES - (write - read);
		if (got > space) {
			got = space; /* the player is behind: drop the excess rather than block */
		}
		for (size_t i = 0; i < got; ++i) {
			size_t at = (write + i) & RING_MASK;
			emu->ring[at * 2] = emu->scratch[i * 2];
			emu->ring[at * 2 + 1] = emu->scratch[i * 2 + 1];
		}
		atomic_store_explicit(&emu->ringWrite, write + got, memory_order_release);
	}
}

void emu_run_frame(EmuCore* emu, bool discardAudio) {
	if (!emu || !emu->core) {
		return;
	}
	struct mCore* core = emu->core;
	core->setKeys(core, atomic_load_explicit(&emu->keys, memory_order_relaxed));
	core->runFrame(core);
	pump_audio(emu, discardAudio);
}

void emu_set_keys(EmuCore* emu, uint32_t keys) {
	if (emu) {
		atomic_store_explicit(&emu->keys, keys, memory_order_relaxed);
	}
}

const uint8_t* emu_video_buffer(const EmuCore* emu) {
	return emu ? (const uint8_t*) emu->video : NULL;
}

unsigned emu_audio_rate(const EmuCore* emu) {
	(void) emu;
	return OUTPUT_RATE;
}

unsigned emu_native_audio_rate(EmuCore* emu) {
	return emu && emu->core ? emu->core->audioSampleRate(emu->core) : 0;
}

size_t emu_audio_read(EmuCore* emu, int16_t* out, size_t frames) {
	if (!emu || !out) {
		return 0;
	}
	size_t read = atomic_load_explicit(&emu->ringRead, memory_order_relaxed);
	size_t write = atomic_load_explicit(&emu->ringWrite, memory_order_acquire);
	if (atomic_exchange(&emu->ringFlush, false)) {
		atomic_store_explicit(&emu->ringRead, write, memory_order_release);
		return 0;
	}
	size_t available = write - read;
	if (frames > available) {
		frames = available;
	}
	for (size_t i = 0; i < frames; ++i) {
		size_t at = (read + i) & RING_MASK;
		out[i * 2] = emu->ring[at * 2];
		out[i * 2 + 1] = emu->ring[at * 2 + 1];
	}
	atomic_store_explicit(&emu->ringRead, read + frames, memory_order_release);
	return frames;
}

size_t emu_audio_queued(const EmuCore* emu) {
	if (!emu) {
		return 0;
	}
	size_t write = atomic_load_explicit(&emu->ringWrite, memory_order_acquire);
	size_t read = atomic_load_explicit(&emu->ringRead, memory_order_acquire);
	return write - read;
}

void emu_audio_clear(EmuCore* emu) {
	if (!emu) {
		return;
	}
	/* Only the audio thread may move the read position, so leave it a note. */
	atomic_store(&emu->ringFlush, true);
}

bool emu_save_state(EmuCore* emu, const char* path) {
	if (!emu || !emu->core || !path) {
		return false;
	}
	struct VFile* vf = VFileOpen(path, O_CREAT | O_TRUNC | O_RDWR);
	if (!vf) {
		return false;
	}
	/* No SAVESTATE_SAVEDATA on purpose: a state that carries the battery save
	 * would roll the save file back when loaded, undoing bank transfers. */
	bool ok = mCoreSaveStateNamed(emu->core, vf, SAVESTATE_RTC | SAVESTATE_METADATA);
	vf->close(vf);
	return ok;
}

bool emu_load_state(EmuCore* emu, const char* path) {
	if (!emu || !emu->core || !path) {
		return false;
	}
	struct VFile* vf = VFileOpen(path, O_RDONLY);
	if (!vf) {
		return false;
	}
	bool ok = mCoreLoadStateNamed(emu->core, vf, SAVESTATE_RTC);
	vf->close(vf);
	emu_audio_clear(emu);
	return ok;
}

size_t emu_read_bytes(EmuCore* emu, uint32_t address, uint8_t* out, size_t length) {
	if (!emu || !emu->core || !out) {
		return 0;
	}
	struct mCore* core = emu->core;
	for (size_t i = 0; i < length; ++i) {
		out[i] = (uint8_t) core->rawRead8(core, address + (uint32_t) i, -1);
	}
	return length;
}

size_t emu_write_bytes(EmuCore* emu, uint32_t address, const uint8_t* in, size_t length) {
	if (!emu || !emu->core || !in) {
		return 0;
	}
	/* RAM only: never the ROM, the BIOS or the cartridge save. */
	uint32_t region = address >> 24;
	if (region != 0x02 && region != 0x03) {
		return 0;
	}
	struct mCore* core = emu->core;
	for (size_t i = 0; i < length; ++i) {
		core->rawWrite8(core, address + (uint32_t) i, -1, in[i]);
	}
	return length;
}

void emu_game_code(const EmuCore* emu, char out[5]) {
	memset(out, 0, 5);
	if (emu && emu->rom && emu->romSize >= 0xC0) {
		memcpy(out, emu->rom + 0xAC, 4);
	}
}

void emu_game_title(const EmuCore* emu, char out[13]) {
	memset(out, 0, 13);
	if (emu && emu->rom && emu->romSize >= 0xC0) {
		memcpy(out, emu->rom + 0xA0, 12);
	}
}

uint8_t emu_revision(const EmuCore* emu) {
	return emu && emu->rom && emu->romSize >= 0xC0 ? emu->rom[0xBC] : 0;
}

const uint8_t* emu_rom_data(const EmuCore* emu, size_t* sizeOut) {
	if (sizeOut) {
		*sizeOut = emu ? emu->romSize : 0;
	}
	return emu ? emu->rom : NULL;
}
