#!/usr/bin/env python3
"""Writes the AltStore / SideStore source for the latest build.

    altstore_source.py IPA VERSION BUILD DOWNLOAD_URL NOTES OUT

Added once in AltStore (Sources > +, its URL), the source makes each new build show up as an
update of the installed app: installed over it, the app keeps its ROMs, saves and bank.
"""
import datetime
import json
import os
import sys

ipa, version, build, url, notes, out = sys.argv[1:7]
repo = "https://raw.githubusercontent.com/louislovni/capsule/main"
source = {
    "name": "Capsule",
    "identifier": "app.capsule.source",
    "subtitle": "GBA, Game Boy et DS, avec PokeDaisy et une banque Pokémon.",
    "description": "Les versions de Capsule, compilées par GitHub Actions depuis github.com/louislovni/capsule.",
    "iconURL": f"{repo}/assets/icon.png",
    "website": "https://github.com/louislovni/capsule",
    "tintColor": "#5B2E9E",
    "apps": [
        {
            "name": "Capsule",
            "bundleIdentifier": "app.capsule.gba",
            "developerName": "louislovni",
            "subtitle": "Émulateur Pokémon avec PokeDaisy et une banque.",
            "localizedDescription": "GBA, Game Boy (Color) et DS, avec le compagnon PokeDaisy, une banque Pokémon "
                                    "pour toutes les générations, des échanges et la sauvegarde dans le cloud.",
            "iconURL": f"{repo}/assets/icon.png",
            "tintColor": "#5B2E9E",
            "category": "games",
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "localizedDescription": notes,
                    "downloadURL": url,
                    "size": os.path.getsize(ipa),
                    "minOSVersion": "16.0",
                }
            ],
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSLocalNetworkUsageDescription":
                        "Capsule cherche les iPhones proches pour échanger des Pokémon entre banques.",
                },
            },
        }
    ],
    "news": [],
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
print(f"source: Capsule {version} ({build}) -> {url}")
