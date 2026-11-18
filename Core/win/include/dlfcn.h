/* dlopen and friends for Windows builds: LoadLibrary / GetProcAddress / FreeLibrary. */
#ifndef CAPSULE_WIN_DLFCN_H
#define CAPSULE_WIN_DLFCN_H
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <stdio.h>
#include <windows.h>

#define RTLD_LAZY 1
#define RTLD_NOW 2
#define RTLD_GLOBAL 0x100
#define RTLD_LOCAL 0

static char capsule_dlerror_text[256];
static int capsule_dlerror_set;

static inline void* dlopen(const char* path, int flags) {
	(void) flags;
	HMODULE h = LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
	if (!h) {
		snprintf(capsule_dlerror_text, sizeof capsule_dlerror_text, "LoadLibrary %s: error %lu", path ? path : "?",
		         (unsigned long) GetLastError());
		capsule_dlerror_set = 1;
	}
	return (void*) h;
}

static inline void* dlsym(void* handle, const char* name) {
	void* p = (void*) (uintptr_t) GetProcAddress((HMODULE) handle, name);
	if (!p) {
		snprintf(capsule_dlerror_text, sizeof capsule_dlerror_text, "GetProcAddress %s: not found", name);
		capsule_dlerror_set = 1;
	}
	return p;
}

static inline int dlclose(void* handle) {
	return FreeLibrary((HMODULE) handle) ? 0 : -1;
}

static inline char* dlerror(void) {
	if (!capsule_dlerror_set) return NULL;
	capsule_dlerror_set = 0;
	return capsule_dlerror_text;
}
#endif
