/* Capsule's co-op ("JOUER A DEUX") in PokeDaisy's desktop frontend (linux/main.c built with CAPSULE_COOP): PokeDaisy's
 * co-op link, so two players of Pokémon Emerald see each other on the map, on the same Wi-Fi as an iPhone or Android
 * device. The protocol is Core/coop's; this adds the sockets, the LAN discovery (mDNS, `_pdcoop._tcp`) and a page of
 * the pause menu. Everything runs on the frontend's one thread: poll it every loop. */
#ifndef CAPSULE_COOP_H
#define CAPSULE_COOP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The core's presence (pd_libretro.c's retro_pd_coop_*), NULL members when it has none. */
struct capsule_coop_core {
	int (*available)(void);
	int (*frame)(uint32_t now, uint8_t* out);
	void (*receive)(const uint8_t* msg, size_t n, uint32_t now);
	void (*stop)(void);
	/* Joined battles (retro_pd_coop_battle_*): the partner's messages in, the game's out, the link's state. */
	void (*battle_in)(int type, const uint8_t* bytes, size_t n);
	int (*battle_out)(int* type, uint8_t* out, int cap);
	void (*battle_link)(int connected);
};

/* Where its key and pairs are kept (a folder made if missing). Once, before a game. */
void capsule_coop_init(const char* dataDir);
/* A GBA game is loaded: its ROM, its battery save's file and the core's presence. */
void capsule_coop_game(const unsigned char* rom, size_t romSize, const char* savPath, const struct capsule_coop_core* core);
/* The game is closing. */
void capsule_coop_game_end(void);
/* Every loop of the game, menu up or not: sockets, discovery, the link. */
void capsule_coop_poll(void);
/* After each frame the core ran: the player's presence out, the partner's in. */
void capsule_coop_after_run(void);
/* A notice to show ("" = none), once. */
const char* capsule_coop_notice(void);

/* The pause menu's row: shown only for a game co-op can play. */
bool capsule_coop_offered(void);
const char* capsule_coop_menu_row(void);
/* Its page, rebuilt every frame: the title and rows (at most max), their count. */
int capsule_coop_page(const char** title, const char** rows, int max);
/* A row picked (A); true = leave the page. */
bool capsule_coop_page_pick(int row);
/* The page is left (B or a pick): an open invite closes. */
void capsule_coop_page_left(void);

#endif
