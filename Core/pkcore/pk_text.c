/* Generation 3 Western character set -> UTF-8. GPL v3. */
#include "pkcore.h"

#include <string.h>

static const char* const kLow[0x30] = {
	/* 0x00 */ " ", "À", "Á", "Â", "Ç", "È", "É", "Ê", "Ë", "Ì", NULL, "Î", "Ï", "Ò", "Ó", "Ô",
	/* 0x10 */ "Œ", "Ù", "Ú", "Û", "Ñ", "ß", "à", "á", NULL, "ç", "è", "é", "ê", "ë", "ì", NULL,
	/* 0x20 */ "î", "ï", "ò", "ó", "ô", "œ", "ù", "ú", "û", "ñ", "º", "ª", NULL, "&", "+", NULL,
};

static const char* pk_char(uint8_t c, char scratch[2]) {
	if (c < 0x30) {
		return kLow[c];
	}
	if (c >= 0xA1 && c <= 0xAA) {
		scratch[0] = (char) ('0' + (c - 0xA1));
		return scratch;
	}
	if (c >= 0xBB && c <= 0xD4) {
		scratch[0] = (char) ('A' + (c - 0xBB));
		return scratch;
	}
	if (c >= 0xD5 && c <= 0xEE) {
		scratch[0] = (char) ('a' + (c - 0xD5));
		return scratch;
	}
	switch (c) {
	case 0x34: return "Lv";
	case 0x35: return "=";
	case 0x36: return ";";
	case 0x51: return "¿";
	case 0x52: return "¡";
	case 0x5A: return "Í";
	case 0x5B: return "%";
	case 0x5C: return "(";
	case 0x5D: return ")";
	case 0x68: return "â";
	case 0x6F: return "í";
	case 0xAB: return "!";
	case 0xAC: return "?";
	case 0xAD: return ".";
	case 0xAE: return "-";
	case 0xAF: return "·";
	case 0xB0: return "…";
	case 0xB1: return "“";
	case 0xB2: return "”";
	case 0xB3: return "‘";
	case 0xB4: return "’";
	case 0xB5: return "♂";
	case 0xB6: return "♀";
	case 0xB8: return ",";
	case 0xB9: return "×";
	case 0xBA: return "/";
	case 0xEF: return "▶";
	case 0xF0: return ":";
	case 0xF1: return "Ä";
	case 0xF2: return "Ö";
	case 0xF3: return "Ü";
	case 0xF4: return "ä";
	case 0xF5: return "ö";
	case 0xF6: return "ü";
	default: return NULL;
	}
}

size_t pk_text_decode(const uint8_t* in, size_t maxLen, char* out, size_t outSize) {
	size_t n = 0;
	if (!out || outSize == 0) {
		return 0;
	}
	for (size_t i = 0; in && i < maxLen; ++i) {
		uint8_t c = in[i];
		if (c == 0xFF) {
			break;
		}
		char scratch[2] = { 0, 0 };
		const char* s = pk_char(c, scratch);
		if (!s) {
			s = "?";
		}
		size_t len = strlen(s);
		if (n + len + 1 > outSize) {
			break;
		}
		memcpy(out + n, s, len);
		n += len;
	}
	out[n] = '\0';
	return n;
}
