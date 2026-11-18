/* Force-included in Windows (MinGW) builds of PokeDaisy's sources: the few POSIX calls they use. */
#ifndef CAPSULE_WIN_COMPAT_H
#define CAPSULE_WIN_COMPAT_H
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
/* windows.h first, once, so its old "near" / "far" / "small" macros can go: the sources use them as names. */
#include <windows.h>
#undef near
#undef far
#undef small
#undef interface
#undef ERROR
#undef IN
#undef OUT
#undef OPTIONAL
#include <direct.h>
#include <io.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <stdlib.h>
#include <time.h>
/* Files open in binary mode: Windows would otherwise translate line ends in ROMs and saves. */
#define O_CLOEXEC _O_BINARY
#define _SC_PAGESIZE 30
/* No hang-up signal on Windows: signal() refuses the number, nothing else happens. */
#define SIGHUP 1
static inline long sysconf(int name) { return name == _SC_PAGESIZE ? 4096 : -1; }
#ifdef __cplusplus
/* POSIX mkdir takes a mode; Windows' doesn't. */
static inline int mkdir(const char* path, int mode) { (void) mode; return _mkdir(path); }
#else
/* Declared above, so the macro only changes the calls. */
#define mkdir(path, mode) _mkdir(path)
#endif
static inline int fsync(int fd) { return _commit(fd); }
static inline char* realpath(const char* path, char* resolved) { return _fullpath(resolved, path, 260); }
#ifdef __cplusplus
/* (mGBA, in C, brings its own.) */
static inline struct tm* localtime_r(const time_t* t, struct tm* out) { return localtime_s(out, t) == 0 ? out : NULL; }
static inline struct tm* gmtime_r(const time_t* t, struct tm* out) { return gmtime_s(out, t) == 0 ? out : NULL; }
#endif
#endif
#endif
