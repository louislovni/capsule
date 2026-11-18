/* A small sys/mman.h for Windows builds of DSperate: anonymous memory through VirtualAlloc.
 * Files are not mapped (MAP_FAILED: DSperate reads the ROM into memory instead), nor fixed
 * addresses (only its recompiler's fast memory uses them, and Windows builds have no recompiler). */
#ifndef CAPSULE_WIN_MMAN_H
#define CAPSULE_WIN_MMAN_H
#include <errno.h>
#include <stddef.h>
#include <sys/types.h>
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_EXEC 4
#define MAP_SHARED 0x01
#define MAP_PRIVATE 0x02
#define MAP_FIXED 0x10
#define MAP_ANONYMOUS 0x20
#define MAP_ANON MAP_ANONYMOUS
#define MAP_NORESERVE 0x4000
#define MAP_FAILED ((void*) -1)

static inline DWORD capsule_win_protect(int prot) {
	if (prot & PROT_EXEC) return (prot & PROT_WRITE) ? PAGE_EXECUTE_READWRITE : PAGE_EXECUTE_READ;
	if (prot & PROT_WRITE) return PAGE_READWRITE;
	if (prot & PROT_READ) return PAGE_READONLY;
	return PAGE_NOACCESS;
}

static inline void* mmap(void* addr, size_t length, int prot, int flags, int fd, long long offset) {
	(void) offset;
	if (!(flags & MAP_ANONYMOUS) || fd != -1 || (flags & MAP_FIXED) || addr) {
		errno = ENODEV;
		return MAP_FAILED;
	}
	/* PROT_NONE: reserved only, committed later by mprotect. */
	void* p = VirtualAlloc(NULL, length, prot == PROT_NONE ? MEM_RESERVE : (MEM_RESERVE | MEM_COMMIT),
	                       prot == PROT_NONE ? PAGE_NOACCESS : capsule_win_protect(prot));
	if (!p) {
		errno = ENOMEM;
		return MAP_FAILED;
	}
	return p;
}

static inline int munmap(void* addr, size_t length) {
	(void) length;
	return VirtualFree(addr, 0, MEM_RELEASE) ? 0 : -1;
}

static inline int mprotect(void* addr, size_t length, int prot) {
	DWORD old;
	if (prot != PROT_NONE && !VirtualAlloc(addr, length, MEM_COMMIT, capsule_win_protect(prot))) return -1;
	return VirtualProtect(addr, length, capsule_win_protect(prot), &old) ? 0 : -1;
}

static inline int madvise(void* addr, size_t length, int advice) {
	(void) addr; (void) length; (void) advice;
	return 0;
}
#define MADV_DONTNEED 4
#define MADV_WILLNEED 3
#define MADV_SEQUENTIAL 2
#define MADV_RANDOM 1
#define MADV_NORMAL 0

static inline int msync(void* addr, size_t length, int flags) {
	(void) addr; (void) length; (void) flags;
	return 0;
}
#define MS_SYNC 4
#define MS_ASYNC 1
#endif
