/* Capsule's co-op on the PC (see capsule_coop.h): non-blocking TCP for Core/coop's host, mDNS for the Wi-Fi (an
 * advertiser and a browser of `_pdcoop._tcp`, what iPhones and Android devices use), and the pause menu's page.
 * Builds on Windows (Winsock) and on Linux (its tests). One thread: the frontend's. */
#include "capsule_coop.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#ifndef _WIN32
#include <strings.h>
#endif

#include "mdns.h"

#ifdef _WIN32
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET sock_t;
#define BAD_SOCK INVALID_SOCKET
#define close_sock closesocket
static bool would_block(void) {
	int e = WSAGetLastError();
	return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS || e == WSAEALREADY;
}
static void make_dir(const char* p) { CreateDirectoryA(p, NULL); }
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
typedef int sock_t;
#define BAD_SOCK (-1)
#define close_sock close
static bool would_block(void) { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINPROGRESS; }
static void make_dir(const char* p) { mkdir(p, 0700); }
#endif

#include "coop_crypto.h"
#include "coop_host.h"
#include "coop_noise.h"

#define SERVICE "_pdcoop._tcp.local."
#define MAX_CONNS 8
#define MAX_LAN 8
#define MAX_PAIRS 8

static int64_t now_ms(void) {
#ifdef _WIN32
	return (int64_t)GetTickCount64();
#else
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
#endif
}

/* CAPSULE_COOP_LOG=1: what the link does, on stderr. */
static void logf_(const char* fmt, ...) {
	static int on = -1;
	if (on < 0)
		on = getenv("CAPSULE_COOP_LOG") != NULL;
	if (!on)
		return;
	va_list a;
	va_start(a, fmt);
	fprintf(stderr, "coop %lld: ", (long long)now_ms());
	vfprintf(stderr, fmt, a);
	fputc('\n', stderr);
	va_end(a);
}

static void set_nonblocking(sock_t s) {
#ifdef _WIN32
	u_long on = 1;
	ioctlsocket(s, FIONBIO, &on);
#else
	fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
	int one = 1;
	setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char*)&one, sizeof one);
}

/* ---- state ---- */

struct conn {
	int id; /* 0 = free slot */
	sock_t s;
	bool outgoing, ready, closing;
	uint8_t* out;
	size_t outLen, outCap;
};

struct lan_entry {
	char instance[96]; /* "" = free */
	char key[65], user[160];
	uint16_t port;
	uint32_t ip; /* network order, 0 = unknown */
	int64_t seen;
	bool told;
};

static struct {
	bool started;
	char dir[1024];
	coop_host* host;
	sock_t listener;
	uint16_t port;
	int mdns;
	uint32_t ip; /* this PC's address on the LAN (network order) */
	char lanName[18], instance[96], hostName[64], txtK[65], txtU[160];
	int64_t nextQuery, nextTick, nextAnnounce, nextIp;
	struct conn conns[MAX_CONNS];
	int nextId;
	struct lan_entry lan[MAX_LAN];
	/* the game */
	bool game, ready, offered;
	uint8_t sha[20];
	char savPath[1100];
	int64_t retryAt;
	struct capsule_coop_core core;
	bool wasLinked;
	int lastLink;
	char notice[96];
	/* the page */
	bool forgetAsked, pairingOpen;
	char title[96], rows[12][48];
	int rowAction[12];
} C = {.listener = BAD_SOCK, .mdns = -1};

/* The menu font draws upper-case ASCII: accents go, the rest is upper case. */
static void fold(const char* in, char* out, size_t outSize) {
	static const struct {
		const char* from;
		char to;
	} map[] = {{"é", 'E'}, {"à", 'A'}, {"â", 'A'}, {"ä", 'A'}, {"À", 'A'}, {"è", 'E'}, {"ê", 'E'}, {"ë", 'E'}, {"É", 'E'}, {"È", 'E'},
	           {"î", 'I'}, {"ï", 'I'}, {"ô", 'O'}, {"ö", 'O'}, {"ù", 'U'}, {"û", 'U'}, {"ü", 'U'}, {"ç", 'C'}, {"ñ", 'N'},
	           {"’", '\''}, {"…", '.'}};
	size_t o = 0;
	while (*in && o + 3 < outSize) {
		unsigned char c = (unsigned char)*in;
		if (c < 0x80) {
			out[o++] = (char)(c >= 'a' && c <= 'z' ? c - 32 : c);
			in++;
			continue;
		}
		bool done = false;
		for (size_t i = 0; i < sizeof map / sizeof *map; i++) {
			size_t n = strlen(map[i].from);
			if (!strncmp(in, map[i].from, n)) {
				out[o++] = map[i].to;
				in += n;
				done = true;
				break;
			}
		}
		if (!done) { /* another character: skipped whole */
			in++;
			while (((unsigned char)*in & 0xC0) == 0x80)
				in++;
		}
	}
	out[o] = 0;
}

static void say(const char* fmt, const char* name) {
	char raw[128];
	snprintf(raw, sizeof raw, fmt, name);
	fold(raw, C.notice, sizeof C.notice);
}

/* ---- connections (the host's io) ---- */

static struct conn* conn_of(int id) {
	for (int i = 0; i < MAX_CONNS; i++)
		if (C.conns[i].id == id)
			return &C.conns[i];
	return NULL;
}

static struct conn* conn_new(sock_t s, bool outgoing) {
	for (int i = 0; i < MAX_CONNS; i++)
		if (!C.conns[i].id) {
			struct conn* c = &C.conns[i];
			memset(c, 0, sizeof *c);
			C.nextId = C.nextId >= 1000000 ? 1 : C.nextId + 1;
			c->id = C.nextId;
			c->s = s;
			c->outgoing = outgoing;
			return c;
		}
	return NULL;
}

static void conn_free(struct conn* c) {
	if (c->s != BAD_SOCK)
		close_sock(c->s);
	free(c->out);
	memset(c, 0, sizeof *c);
	c->s = BAD_SOCK;
}

/* Sends what's queued; false = the socket is gone. */
static bool conn_flush(struct conn* c) {
	while (c->outLen) {
		int n = (int)send(c->s, (const char*)c->out, (int)c->outLen, 0);
		if (n < 0)
			return would_block();
		memmove(c->out, c->out + n, c->outLen - (size_t)n);
		c->outLen -= (size_t)n;
	}
	return true;
}

/* Gone by itself: the host hears of it. */
static void conn_drop(struct conn* c) {
	int id = c->id;
	bool dialing = c->outgoing && !c->ready, ready = c->ready, closing = c->closing;
	logf_("conn %d dropped (%s)", id, dialing ? "dial failed" : "gone");
	conn_free(c);
	if (closing)
		return;
	if (dialing)
		coop_host_dialed(C.host, id, false, now_ms());
	else if (ready)
		coop_host_gone(C.host, id, now_ms());
}

static bool io_write(void* ctx, int id, const uint8_t* bytes, size_t n) {
	(void)ctx;
	struct conn* c = conn_of(id);
	if (!c || !c->ready || c->closing)
		return false;
	if (c->outLen + n > c->outCap) {
		size_t cap = (c->outLen + n) * 2;
		if (cap > 1u << 20)
			return false; /* the other side stopped reading */
		uint8_t* b = realloc(c->out, cap);
		if (!b)
			return false;
		c->out = b, c->outCap = cap;
	}
	memcpy(c->out + c->outLen, bytes, n);
	c->outLen += n;
	conn_flush(c);
	return true;
}

static void io_close(void* ctx, int id) {
	(void)ctx;
	struct conn* c = conn_of(id);
	if (!c)
		return;
	if (c->ready)
		conn_flush(c);
	c->closing = true; /* freed by the poll (not under the host's feet) */
	logf_("conn %d closed by the host", id);
}

static int io_dial(void* ctx, const coop_address* a) {
	(void)ctx;
	if (a->family != 4)
		return -1;
	sock_t s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (s == BAD_SOCK)
		return -1;
	set_nonblocking(s);
	struct sockaddr_in to = {0};
	to.sin_family = AF_INET;
	memcpy(&to.sin_addr, a->addr, 4);
	to.sin_port = htons(a->port);
	if (connect(s, (struct sockaddr*)&to, sizeof to) != 0 && !would_block()) {
		close_sock(s);
		return -1;
	}
	struct conn* c = conn_new(s, true);
	if (!c) {
		close_sock(s);
		return -1;
	}
	logf_("conn %d dialing %d.%d.%d.%d:%d", c->id, a->addr[0], a->addr[1], a->addr[2], a->addr[3], a->port);
	return c->id;
}

static void io_presence(void* ctx, const uint8_t* bytes, size_t n) {
	(void)ctx;
	if (C.game && C.core.receive)
		C.core.receive(bytes, n, (uint32_t)now_ms());
}

/* ---- this PC on the LAN ---- */

/* The address the LAN sees (the interface multicast goes out of): no packet is sent. */
static uint32_t lan_ip(void) {
	sock_t s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (s == BAD_SOCK)
		return 0;
	struct sockaddr_in to = {0};
	to.sin_family = AF_INET;
	to.sin_port = htons(MDNS_PORT);
	to.sin_addr.s_addr = htonl(0xE00000FBu);
	uint32_t ip = 0;
	if (connect(s, (struct sockaddr*)&to, sizeof to) == 0) {
		struct sockaddr_in me;
		socklen_t n = sizeof me;
		if (getsockname(s, (struct sockaddr*)&me, &n) == 0)
			ip = me.sin_addr.s_addr;
	}
	close_sock(s);
	/* No route to the multicast group (no network): try the default route. */
	if (!ip || ip == htonl(INADDR_LOOPBACK)) {
		s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
		if (s == BAD_SOCK)
			return 0;
		to.sin_addr.s_addr = htonl(0x0A000001u);
		if (connect(s, (struct sockaddr*)&to, sizeof to) == 0) {
			struct sockaddr_in me;
			socklen_t n = sizeof me;
			if (getsockname(s, (struct sockaddr*)&me, &n) == 0)
				ip = me.sin_addr.s_addr;
		}
		close_sock(s);
	}
	return ip == htonl(INADDR_LOOPBACK) ? 0 : ip;
}

static void addresses_update(void) {
	coop_address a = {0};
	a.family = 4;
	memcpy(a.addr, &C.ip, 4);
	a.port = C.port;
	coop_host_set_addresses(C.host, &a, C.ip ? 1 : 0);
}

static void mdns_open(void) {
	if (C.mdns >= 0) {
		mdns_socket_close(C.mdns);
		C.mdns = -1;
	}
	struct sockaddr_in at = {0};
	at.sin_family = AF_INET;
	at.sin_port = htons(MDNS_PORT);
	at.sin_addr.s_addr = C.ip;
	C.mdns = mdns_socket_open_ipv4(C.ip ? &at : NULL);
	if (C.mdns < 0 && C.ip) { /* the interface refused: any */
		at.sin_addr.s_addr = INADDR_ANY;
		C.mdns = mdns_socket_open_ipv4(&at);
	}
}

static uint32_t sendBuf[1024], recvBuf[1024];

/* Our records: the service's PTR to the instance, its SRV, TXT and the host's A. */
static void records(mdns_record_t* ptr, mdns_record_t* srv, mdns_record_t* a, mdns_record_t txt[2], int* txtCount) {
	mdns_string_t service = {SERVICE, strlen(SERVICE)};
	mdns_string_t instance = {C.instance, strlen(C.instance)};
	mdns_string_t hostName = {C.hostName, strlen(C.hostName)};
	*ptr = (mdns_record_t){.name = service, .type = MDNS_RECORDTYPE_PTR, .data.ptr.name = instance, .rclass = 0, .ttl = 120};
	*srv = (mdns_record_t){.name = instance, .type = MDNS_RECORDTYPE_SRV, .rclass = 0, .ttl = 120};
	srv->data.srv.port = C.port;
	srv->data.srv.name = hostName;
	*a = (mdns_record_t){.name = hostName, .type = MDNS_RECORDTYPE_A, .rclass = 0, .ttl = 120};
	a->data.a.addr.sin_family = AF_INET;
	a->data.a.addr.sin_addr.s_addr = C.ip;
	int n = 0;
	txt[n] = (mdns_record_t){.name = instance, .type = MDNS_RECORDTYPE_TXT, .rclass = 0, .ttl = 120};
	txt[n].data.txt.key = (mdns_string_t){"k", 1};
	txt[n++].data.txt.value = (mdns_string_t){C.txtK, strlen(C.txtK)};
	if (C.txtU[0]) {
		txt[n] = (mdns_record_t){.name = instance, .type = MDNS_RECORDTYPE_TXT, .rclass = 0, .ttl = 120};
		txt[n].data.txt.key = (mdns_string_t){"u", 1};
		txt[n++].data.txt.value = (mdns_string_t){C.txtU, strlen(C.txtU)};
	}
	*txtCount = n;
}

static void announce(void) {
	if (C.mdns < 0 || !C.port)
		return;
	mdns_record_t ptr, srv, a, txt[2], extra[4];
	int t, n = 0;
	records(&ptr, &srv, &a, txt, &t);
	extra[n++] = srv;
	for (int i = 0; i < t; i++)
		extra[n++] = txt[i];
	if (C.ip)
		extra[n++] = a;
	mdns_announce_multicast(C.mdns, sendBuf, sizeof sendBuf, ptr, NULL, 0, extra, (size_t)n);
}

static struct lan_entry* lan_of(const char* instance, bool make) {
	struct lan_entry* freeSlot = NULL;
	for (int i = 0; i < MAX_LAN; i++) {
		if (C.lan[i].instance[0] && !strcmp(C.lan[i].instance, instance))
			return &C.lan[i];
		if (!C.lan[i].instance[0] && !freeSlot)
			freeSlot = &C.lan[i];
	}
	if (!make || !freeSlot)
		return NULL;
	memset(freeSlot, 0, sizeof *freeSlot);
	snprintf(freeSlot->instance, sizeof freeSlot->instance, "%s", instance);
	return freeSlot;
}

static void lan_forget(struct lan_entry* e) {
	if (e->told && e->key[0])
		coop_host_lan_lost(C.host, e->key);
	memset(e, 0, sizeof *e);
}

/* Host names to addresses seen in this packet, and the packet's sender. */
static struct {
	char host[8][64];
	uint32_t ip[8];
	int n;
	uint32_t from;
} pkt;

static bool ends_with_service(const char* name, size_t len) {
	size_t s = strlen(SERVICE);
	return len > s && !strncasecmp(name + len - s, SERVICE, s);
}

static int mdns_record(int sock, const struct sockaddr* from, size_t addrlen, mdns_entry_type_t entry, uint16_t queryId,
                       uint16_t rtype, uint16_t rclass, uint32_t ttl, const void* data, size_t size, size_t nameOffset,
                       size_t nameLength, size_t recordOffset, size_t recordLength, void* user) {
	(void)nameLength, (void)user;
	char name[256];
	size_t off = nameOffset;
	mdns_string_t nm = mdns_string_extract(data, size, &off, name, sizeof name);
	if (from->sa_family == AF_INET)
		pkt.from = ((const struct sockaddr_in*)from)->sin_addr.s_addr;
	if (entry == MDNS_ENTRYTYPE_QUESTION) {
		if (!C.port || !C.instance[0])
			return 0;
		mdns_record_t ptr, srv, a, txt[2], extra[4];
		int t, n = 0;
		records(&ptr, &srv, &a, txt, &t);
		mdns_record_t answer;
		bool any = rtype == MDNS_RECORDTYPE_ANY;
		static const char dnsSd[] = "_services._dns-sd._udp.local.";
		if (nm.length == strlen(dnsSd) && !strncasecmp(nm.str, dnsSd, nm.length) && (rtype == MDNS_RECORDTYPE_PTR || any)) {
			answer = (mdns_record_t){.name = nm, .type = MDNS_RECORDTYPE_PTR, .data.ptr.name = ptr.name, .ttl = 120};
		} else if (nm.length == strlen(SERVICE) && !strncasecmp(nm.str, SERVICE, nm.length) && (rtype == MDNS_RECORDTYPE_PTR || any)) {
			answer = ptr;
			extra[n++] = srv;
			for (int i = 0; i < t; i++)
				extra[n++] = txt[i];
			if (C.ip)
				extra[n++] = a;
		} else if (nm.length == strlen(C.instance) && !strncasecmp(nm.str, C.instance, nm.length) &&
		           (rtype == MDNS_RECORDTYPE_SRV || rtype == MDNS_RECORDTYPE_TXT || any)) {
			if (rtype == MDNS_RECORDTYPE_TXT) {
				answer = txt[0];
				for (int i = 1; i < t; i++)
					extra[n++] = txt[i];
				extra[n++] = srv;
			} else {
				answer = srv;
				for (int i = 0; i < t; i++)
					extra[n++] = txt[i];
			}
			if (C.ip)
				extra[n++] = a;
		} else if (nm.length == strlen(C.hostName) && !strncasecmp(nm.str, C.hostName, nm.length) &&
		           (rtype == MDNS_RECORDTYPE_A || any) && C.ip) {
			answer = a;
		} else
			return 0;
		if (rclass & MDNS_UNICAST_RESPONSE)
			mdns_query_answer_unicast(sock, from, addrlen, sendBuf, sizeof sendBuf, queryId, (mdns_record_type_t)rtype, nm.str,
			                          nm.length, answer, NULL, 0, extra, (size_t)n);
		else
			mdns_query_answer_multicast(sock, sendBuf, sizeof sendBuf, answer, NULL, 0, extra, (size_t)n);
		return 0;
	}
	/* An answer: another device's records. */
	if (rtype == MDNS_RECORDTYPE_PTR && nm.length == strlen(SERVICE) && !strncasecmp(nm.str, SERVICE, nm.length)) {
		char inst[256];
		mdns_string_t i = mdns_record_parse_ptr(data, size, recordOffset, recordLength, inst, sizeof inst);
		if (i.length && i.length < 96) {
			inst[i.length] = 0;
			if (strcmp(inst, C.instance)) {
				struct lan_entry* e = lan_of(inst, ttl > 0);
				if (e && !ttl)
					lan_forget(e);
				else if (e)
					e->seen = now_ms();
			}
		}
	} else if (rtype == MDNS_RECORDTYPE_SRV && ends_with_service(nm.str, nm.length) && nm.length < 96) {
		name[nm.length] = 0;
		if (strcmp(name, C.instance)) {
			struct lan_entry* e = lan_of(name, ttl > 0);
			if (e && !ttl)
				lan_forget(e);
			else if (e) {
				char target[256];
				mdns_record_srv_t s = mdns_record_parse_srv(data, size, recordOffset, recordLength, target, sizeof target);
				e->port = s.port;
				e->seen = now_ms();
				for (int k = 0; k < pkt.n; k++)
					if (strlen(pkt.host[k]) == s.name.length && !strncasecmp(pkt.host[k], s.name.str, s.name.length))
						e->ip = pkt.ip[k];
				if (!e->ip)
					e->ip = pkt.from;
			}
		}
	} else if (rtype == MDNS_RECORDTYPE_TXT && ends_with_service(nm.str, nm.length) && nm.length < 96) {
		name[nm.length] = 0;
		if (strcmp(name, C.instance)) {
			struct lan_entry* e = lan_of(name, ttl > 0);
			if (e && ttl) {
				mdns_record_txt_t kv[8];
				size_t count = mdns_record_parse_txt(data, size, recordOffset, recordLength, kv, 8);
				char k[65] = "", u[160] = "";
				for (size_t j = 0; j < count; j++) {
					if (kv[j].key.length == 1 && kv[j].key.str[0] == 'k' && kv[j].value.length == 64)
						memcpy(k, kv[j].value.str, 64), k[64] = 0;
					else if (kv[j].key.length == 1 && kv[j].key.str[0] == 'u' && kv[j].value.length < sizeof u)
						memcpy(u, kv[j].value.str, kv[j].value.length), u[kv[j].value.length] = 0;
				}
				if (k[0]) {
					if (e->told && strcmp(e->key, k))
						coop_host_lan_lost(C.host, e->key), e->told = false;
					memcpy(e->key, k, sizeof k);
					if (strcmp(e->user, u))
						e->told = false; /* told again with the new user data */
					snprintf(e->user, sizeof e->user, "%s", u);
				}
				e->seen = now_ms();
			}
		}
	} else if (rtype == MDNS_RECORDTYPE_A && pkt.n < 8 && nm.length < 64) {
		struct sockaddr_in a;
		mdns_record_parse_a(data, size, recordOffset, recordLength, &a);
		memcpy(pkt.host[pkt.n], nm.str, nm.length);
		pkt.host[pkt.n][nm.length] = 0;
		pkt.ip[pkt.n++] = a.sin_addr.s_addr;
	}
	return 0;
}

static void lan_poll(int64_t now) {
	if (C.mdns < 0)
		return;
	for (int guard = 0; guard < 64; guard++) {
		memset(&pkt, 0, sizeof pkt);
		if (!mdns_socket_listen(C.mdns, recvBuf, sizeof recvBuf, mdns_record, NULL))
			break;
	}
	for (int i = 0; i < MAX_LAN; i++) {
		struct lan_entry* e = &C.lan[i];
		if (!e->instance[0])
			continue;
		if (now - e->seen > 30000) {
			lan_forget(e);
			continue;
		}
		if (!e->told && e->key[0] && strcmp(e->key, C.txtK) && e->port && e->ip) {
			coop_address a = {0};
			a.family = 4;
			memcpy(a.addr, &e->ip, 4);
			a.port = e->port;
			coop_host_lan_seen(C.host, e->key, e->user, &a);
			e->told = true;
		}
	}
	bool busy = coop_pair_step(C.host) == COOP_PAIR_INVITING || coop_link_state(C.host) == COOP_LINK_CONNECTING;
	if (now >= C.nextQuery) {
		mdns_query_send(C.mdns, MDNS_RECORDTYPE_PTR, SERVICE, strlen(SERVICE), sendBuf, sizeof sendBuf, 0);
		C.nextQuery = now + (busy ? 3000 : 15000);
	}
}

/* ---- starting ---- */

static void start(void) {
	if (C.started)
		return;
	C.started = true;
#ifdef _WIN32
	WSADATA w;
	WSAStartup(MAKEWORD(2, 2), &w);
#endif
	for (int i = 0; i < MAX_CONNS; i++)
		C.conns[i].s = BAD_SOCK;
	char path[1100];
	make_dir(C.dir);
	uint8_t secret[32];
	snprintf(path, sizeof path, "%s/secret.key", C.dir);
	FILE* f = fopen(path, "rb");
	bool have = f && fread(secret, 1, 32, f) == 32;
	if (f)
		fclose(f);
	if (!have) {
		coop_random(secret, 32);
		f = fopen(path, "wb");
		if (f) {
			fwrite(secret, 1, 32, f);
			fclose(f);
		}
	}
	snprintf(path, sizeof path, "%s/pairs.txt", C.dir);
	coop_io io = {NULL, io_write, io_close, io_dial, io_presence};
	C.host = coop_host_new(secret, path, "capsule-pc", io);
	coop_wipe(secret, sizeof secret);
	if (!C.host)
		return;
	coop_host_lan_name(C.host, C.lanName);
	coop_host_peer_hex(C.host, C.txtK);
	snprintf(C.instance, sizeof C.instance, "%s." SERVICE, C.lanName);
	snprintf(C.hostName, sizeof C.hostName, "%s.local.", C.lanName);

	C.listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (C.listener != BAD_SOCK) {
		struct sockaddr_in at = {0};
		at.sin_family = AF_INET;
		at.sin_addr.s_addr = INADDR_ANY;
		socklen_t n = sizeof at;
		if (bind(C.listener, (struct sockaddr*)&at, sizeof at) == 0 && listen(C.listener, 4) == 0 &&
		    getsockname(C.listener, (struct sockaddr*)&at, &n) == 0) {
			set_nonblocking(C.listener);
			C.port = ntohs(at.sin_port);
		} else {
			close_sock(C.listener);
			C.listener = BAD_SOCK;
		}
	}
	C.ip = lan_ip();
	addresses_update();
	mdns_open();
	C.nextIp = now_ms() + 10000;
	announce();
}

/* ---- the frontend's calls ---- */

void capsule_coop_init(const char* dataDir) { snprintf(C.dir, sizeof C.dir, "%s", dataDir); }

/* The battery save's trainer for the host: false while the game has never been saved. */
static bool use_save(void) {
	uint8_t* save = NULL;
	size_t saveLen = 0;
	FILE* f = C.savPath[0] ? fopen(C.savPath, "rb") : NULL;
	if (f) {
		save = malloc(256 * 1024);
		if (save)
			saveLen = fread(save, 1, 256 * 1024, f);
		fclose(f);
	}
	C.ready = save && coop_host_set_game(C.host, C.sha, save, saveLen);
	free(save);
	if (C.ready && coop_pairs_has_current(C.host))
		coop_link_start(C.host, now_ms());
	return C.ready;
}

void capsule_coop_game(const unsigned char* rom, size_t romSize, const char* savPath, const struct capsule_coop_core* core) {
	C.game = true;
	C.ready = C.offered = false;
	C.core = core ? *core : (struct capsule_coop_core){0};
	C.wasLinked = false;
	C.lastLink = COOP_LINK_OFF;
	C.forgetAsked = false;
	if (!C.core.available || !C.core.frame || !C.core.available() || !rom || romSize < 0x200)
		return;
	uint8_t sha[20];
	coop_sha1(rom, romSize, sha);
	if (!coop_rom_accepted(sha))
		return;
	C.offered = true;
	start();
	if (!C.host)
		return;
	memcpy(C.sha, sha, 20);
	snprintf(C.savPath, sizeof C.savPath, "%s", savPath ? savPath : "");
	use_save();
}

void capsule_coop_game_end(void) {
	if (C.host) {
		if (C.pairingOpen)
			coop_pair_close(C.host);
		C.pairingOpen = false;
		coop_link_stop(C.host);
		capsule_coop_poll(); /* the goodbye goes out */
	}
	if (C.wasLinked && C.core.stop)
		C.core.stop();
	C.game = C.ready = C.offered = C.wasLinked = false;
	memset(&C.core, 0, sizeof C.core);
}

void capsule_coop_poll(void) {
	if (!C.host)
		return;
	int64_t now = now_ms();
	/* new connections */
	if (C.listener != BAD_SOCK)
		for (int guard = 0; guard < 4; guard++) {
			sock_t s = accept(C.listener, NULL, NULL);
			if (s == BAD_SOCK)
				break;
			set_nonblocking(s);
			struct conn* c = conn_new(s, false);
			if (!c) {
				close_sock(s);
				continue;
			}
			c->ready = true;
			logf_("conn %d accepted", c->id);
			coop_host_accepted(C.host, c->id, now);
		}
	/* dials finishing, data, writes */
	for (int i = 0; i < MAX_CONNS; i++) {
		struct conn* c = &C.conns[i];
		if (!c->id)
			continue;
		if (c->closing) {
			if (!c->ready || !c->outLen || !conn_flush(c) || !c->outLen)
				conn_free(c);
			continue;
		}
		if (c->outgoing && !c->ready) {
			fd_set w, e;
			FD_ZERO(&w);
			FD_ZERO(&e);
			FD_SET(c->s, &w);
			FD_SET(c->s, &e);
			struct timeval zero = {0, 0};
			if (select((int)c->s + 1, NULL, &w, &e, &zero) <= 0)
				continue;
			int err = 0;
			socklen_t n = sizeof err;
			getsockopt(c->s, SOL_SOCKET, SO_ERROR, (char*)&err, &n);
			if (err || FD_ISSET(c->s, &e)) {
				conn_drop(c);
				continue;
			}
			c->ready = true;
			logf_("conn %d connected", c->id);
			coop_host_dialed(C.host, c->id, true, now);
			continue;
		}
		if (!conn_flush(c)) {
			conn_drop(c);
			continue;
		}
		uint8_t buf[8192];
		for (int guard = 0; guard < 16 && c->id && !c->closing; guard++) {
			int n = (int)recv(c->s, (char*)buf, sizeof buf, 0);
			if (n > 0) {
				int id = c->id;
				coop_host_data(C.host, id, buf, (size_t)n, now);
				if (c->id != id)
					break;
				continue;
			}
			if (n == 0 || !would_block())
				conn_drop(c);
			break;
		}
	}
	/* the Wi-Fi */
	if (now >= C.nextIp) {
		uint32_t ip = lan_ip();
		C.nextIp = now + 10000;
		if (ip != C.ip) {
			C.ip = ip;
			addresses_update();
			mdns_open();
			announce();
		}
	}
	lan_poll(now);
	if (now >= C.nextTick) {
		coop_host_tick(C.host, now);
		C.nextTick = now + 150;
		char u[160];
		coop_host_lan_user_data(C.host, u, sizeof u);
		if (strcmp(u, C.txtU)) {
			snprintf(C.txtU, sizeof C.txtU, "%s", u);
			announce();
		}
	}
	/* paired from the page: the link starts on that connection */
	if (C.pairingOpen && coop_pair_step(C.host) == COOP_PAIR_PAIRED) {
		char name[64];
		int tid = 0;
		coop_pair_partner(C.host, name, sizeof name, &tid);
		say("Associé avec %s", name);
		coop_pair_close(C.host);
		C.pairingOpen = false;
		if (C.ready && coop_pairs_has_current(C.host))
			coop_link_start(C.host, now);
	}
	/* the link: said when it changes */
	int link = coop_link_state(C.host);
	if (link != C.lastLink) {
		logf_("link %d -> %d", C.lastLink, link);
		char name[64];
		coop_link_partner(C.host, name, sizeof name);
		if (link == COOP_LINK_CONNECTED)
			say("%s joue avec toi", name);
		else if (C.lastLink == COOP_LINK_CONNECTED)
			say("Connexion perdue avec %s", name);
		C.lastLink = link;
	}
	bool linked = C.game && link == COOP_LINK_CONNECTED;
	if (C.wasLinked && !linked && C.core.stop)
		C.core.stop(); /* the partner goes from the map */
	C.wasLinked = linked;
}

void capsule_coop_after_run(void) {
	if (!C.host || !C.wasLinked || !C.core.frame)
		return;
	uint8_t out[64];
	if (C.core.frame((uint32_t)now_ms(), out))
		coop_link_send_presence(C.host, out, 20);
}

const char* capsule_coop_notice(void) {
	static char shown[96];
	snprintf(shown, sizeof shown, "%s", C.notice);
	C.notice[0] = 0;
	return shown;
}

/* ---- the page ---- */

enum { ACT_NONE, ACT_BACK, ACT_PAIR, ACT_JOIN, ACT_CANCEL, ACT_ACCEPT, ACT_DENY, ACT_FORGET, ACT_RETRY };

bool capsule_coop_offered(void) { return C.offered; }

const char* capsule_coop_menu_row(void) {
	if (C.host && C.game && coop_link_state(C.host) == COOP_LINK_CONNECTED)
		return "JOUER A DEUX  CONNECTE";
	return "JOUER A DEUX";
}

static int row(int n, int action, const char* text) {
	fold(text, C.rows[n], sizeof C.rows[n]);
	C.rowAction[n] = action;
	return n + 1;
}

static const char* fail_text(int fail) {
	switch (fail) {
	case COOP_FAIL_VERSION: return "VERSION DE LA COOP DIFFERENTE";
	case COOP_FAIL_DIFFERENT_ROM: return "PAS LA MEME VERSION D'EMERAUDE";
	case COOP_FAIL_SAME_SAVE: return "LA MEME SAUVEGARDE DES DEUX COTES";
	case COOP_FAIL_SAVE_ALREADY_PAIRED: return "CETTE PARTIE A DEJA UN PARTENAIRE";
	case COOP_FAIL_DENIED: return "ASSOCIATION REFUSEE";
	case COOP_FAIL_TIMEOUT: return "PAS DE REPONSE A TEMPS";
	case COOP_FAIL_NO_GAME: return "PAS DE PARTIE";
	default: return "CONNEXION IMPOSSIBLE (MEME WI-FI ?)";
	}
}

int capsule_coop_page(const char** title, const char** rows, int max) {
	int n = 0;
	char line[160];
	if (C.host && C.offered && !C.ready && now_ms() >= C.retryAt) {
		C.retryAt = now_ms() + 1000; /* saved since the game started? (the frontend writes the save every 2 s) */
		use_save();
	}
	if (!C.host || !C.ready) {
		fold("Sauvegarde d'abord une fois dans le jeu", C.title, sizeof C.title);
		n = row(n, ACT_BACK, "Retour");
	} else if (coop_pairs_has_current(C.host)) {
		char name[64] = "";
		for (int i = 0; i < coop_pairs_count(C.host); i++) {
			bool current = false;
			char nm[64];
			coop_pairs_get(C.host, i, nm, sizeof nm, &current);
			if (current)
				snprintf(name, sizeof name, "%s", nm);
		}
		int link = coop_link_state(C.host);
		snprintf(line, sizeof line, "Partenaire : %s", name);
		fold(line, C.title, sizeof C.title);
		n = row(n, ACT_NONE, link == COOP_LINK_CONNECTED ? "Connecté : vous vous voyez sur la carte"
		                                                 : "Recherche du partenaire sur le Wi-Fi...");
		n = row(n, ACT_FORGET, C.forgetAsked ? "Vraiment oublier ce partenaire ?" : "Oublier ce partenaire");
		n = row(n, ACT_BACK, "Retour");
	} else {
		char name[64];
		int tid = 0;
		coop_pair_partner(C.host, name, sizeof name, &tid);
		switch (coop_pair_step(C.host)) {
		case COOP_PAIR_INVITING: {
			fold("Joueurs sur le Wi-Fi", C.title, sizeof C.title);
			int count = coop_pair_nearby_count(C.host);
			for (int i = 0; i < count && n < max - 2 && n < 9; i++) {
				char key[65], label[64];
				coop_pair_nearby(C.host, i, key, label, sizeof label);
				n = row(n, ACT_JOIN + 100 * (i + 1), label[0] ? label : "Joueur");
			}
			if (!count)
				n = row(n, ACT_NONE, "Recherche... ouvre JOUER A DEUX en face");
			n = row(n, ACT_CANCEL, "Annuler");
			break;
		}
		case COOP_PAIR_CONNECTING:
			fold("Connexion...", C.title, sizeof C.title);
			n = row(n, ACT_CANCEL, "Annuler");
			break;
		case COOP_PAIR_CONFIRM:
			snprintf(line, sizeof line, "Jouer avec %s (ID %05d) ?", name, tid);
			fold(line, C.title, sizeof C.title);
			n = row(n, ACT_DENY, "Refuser");
			n = row(n, ACT_ACCEPT, "Accepter");
			break;
		case COOP_PAIR_WAITING:
			snprintf(line, sizeof line, "En attente de %s...", name);
			fold(line, C.title, sizeof C.title);
			n = row(n, ACT_CANCEL, "Annuler");
			break;
		case COOP_PAIR_FAILED:
			fold(fail_text(coop_pair_fail(C.host)), C.title, sizeof C.title);
			n = row(n, ACT_RETRY, "Réessayer");
			n = row(n, ACT_BACK, "Retour");
			break;
		default:
			fold("Jouer à deux (même Wi-Fi)", C.title, sizeof C.title);
			n = row(n, ACT_PAIR, "Associer un joueur proche");
			n = row(n, ACT_BACK, "Retour");
		}
	}
	*title = C.title;
	for (int i = 0; i < n && i < max; i++)
		rows[i] = C.rows[i];
	return n < max ? n : max;
}

bool capsule_coop_page_pick(int r) {
	if (r < 0 || r >= 12 || !C.host)
		return true;
	int64_t now = now_ms();
	int action = C.rowAction[r];
	if (action != ACT_FORGET)
		C.forgetAsked = false;
	if (action >= 100) {
		int i = action / 100 - 1;
		char key[65], label[64];
		if (i < coop_pair_nearby_count(C.host)) {
			coop_pair_nearby(C.host, i, key, label, sizeof label);
			coop_pair_join_lan(C.host, key, now);
		}
		return false;
	}
	switch (action) {
	case ACT_BACK:
		return true;
	case ACT_PAIR:
	case ACT_RETRY:
		coop_pair_open(C.host, now);
		C.pairingOpen = true;
		C.nextQuery = 0; /* look now */
		return false;
	case ACT_CANCEL:
		coop_pair_close(C.host);
		C.pairingOpen = false;
		return false;
	case ACT_ACCEPT:
		coop_pair_accept(C.host, now);
		return false;
	case ACT_DENY:
		coop_pair_deny(C.host, now);
		return false;
	case ACT_FORGET:
		if (!C.forgetAsked) {
			C.forgetAsked = true;
			return false;
		}
		C.forgetAsked = false;
		coop_link_stop(C.host);
		for (int i = 0; i < coop_pairs_count(C.host); i++) {
			bool current = false;
			char nm[64];
			coop_pairs_get(C.host, i, nm, sizeof nm, &current);
			if (current) {
				coop_pairs_remove(C.host, i);
				break;
			}
		}
		return false;
	default:
		return false;
	}
}

void capsule_coop_page_left(void) {
	if (!C.host)
		return;
	C.forgetAsked = false;
	int step = coop_pair_step(C.host);
	if (C.pairingOpen && step != COOP_PAIR_PAIRED && step != COOP_PAIR_WAITING && step != COOP_PAIR_CONFIRM) {
		coop_pair_close(C.host);
		C.pairingOpen = false;
	}
}
