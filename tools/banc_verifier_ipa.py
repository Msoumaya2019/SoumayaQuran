#!/usr/bin/env python3
"""Banc de `verifier_ipa.py` — un controle jamais falsifie ne vaut rien.

Le controle vert sur un vrai IPA ne prouve pas qu'il sait REFUSER. Ce banc
fabrique donc de faux IPA, entierement en memoire et hors du depot, pour
eprouver les trois refus qui comptent — et le temoin qui doit passer.

Les trois refus :

  1. **compilation de simulateur** — `DTPlatformName` vaut `iphonesimulator`.
     C'est le defaut le plus couteux : le fichier a la forme d'un IPA et ne
     s'installera sur aucun iPhone, meme signe ;
  2. **binaire de simulateur sous un Info.plist d'appareil** — le mensonge est
     dans l'en-tete Mach-O (`LC_BUILD_VERSION`, plateforme 7). Il faut donc
     lire le binaire, pas seulement le plist ;
  3. **code Dart absent** — le paquet ne porte pas les chaines du projet : une
     compilation d'un autre commit passerait un build vert.

Et le temoin : un faux IPA correct doit etre ACCEPTE. Sans lui, un controle qui
refuserait tout passerait pour concluant.

Usage : python tools/banc_verifier_ipa.py
"""

from __future__ import annotations

import plistlib
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
CONTROLE = RACINE / "tools" / "verifier_ipa.py"

TEMOINS = ["apis.quran.foundation", "verses.quran.foundation", "snapshots/mushafs", "by_page"]


def binaire_macho(plateforme: int) -> bytes:
    """Fabrique un Mach-O 64 bits minimal portant un LC_BUILD_VERSION."""
    # En-tete 64 bits : 32 octets.
    en_tete = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,  # magie
        0x0100000C,  # cputype arm64
        0,
        2,  # filetype MH_EXECUTE
        1,  # ncmds
        24,  # sizeofcmds
        0,
        0,
    )
    commande = struct.pack("<IIIIII", 0x32, 24, plateforme, 0x000F0000, 0x000F0000, 0)
    return en_tete + commande


def fabriquer_ipa(
    dossier: Path,
    *,
    plateforme_plist: str,
    supportees: list[str],
    plateforme_macho: int,
    avec_temoins: bool,
) -> Path:
    app = dossier / "Payload" / "Runner.app"
    (app / "Frameworks" / "App.framework").mkdir(parents=True, exist_ok=True)

    plist = {
        "DTPlatformName": plateforme_plist,
        "CFBundleSupportedPlatforms": supportees,
        "CFBundleIdentifier": "fr.fcpe.montmagny.soumaya",
        "CFBundleExecutable": "Runner",
        "MinimumOSVersion": "15.0",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
    }
    (app / "Info.plist").write_bytes(plistlib.dumps(plist))
    (app / "Runner").write_bytes(binaire_macho(plateforme_macho))

    instantane = b"remplissage" * 64
    if avec_temoins:
        instantane += "".join(TEMOINS).encode()
    (app / "Frameworks" / "App.framework" / "App").write_bytes(instantane)

    ipa = dossier / "faux.ipa"
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
        for chemin in sorted(app.rglob("*")):
            if chemin.is_file():
                archive.write(chemin, chemin.relative_to(dossier))
    return ipa


CAS = [
    (
        "compilation de simulateur",
        dict(
            plateforme_plist="iphonesimulator",
            supportees=["iPhoneSimulator"],
            plateforme_macho=7,
            avec_temoins=True,
        ),
        ["DTPlatformName", "iOSSimulator"],
    ),
    (
        "binaire de simulateur sous un plist d'appareil",
        dict(
            plateforme_plist="iphoneos",
            supportees=["iPhoneOS"],
            plateforme_macho=7,
            avec_temoins=True,
        ),
        ["iOSSimulator"],
    ),
    (
        "code Dart absent",
        dict(
            plateforme_plist="iphoneos",
            supportees=["iPhoneOS"],
            plateforme_macho=2,
            avec_temoins=False,
        ),
        ["temoin(s) Dart"],
    ),
]


def lancer(ipa: Path) -> tuple[int, str]:
    resultat = subprocess.run(
        [sys.executable, "-u", str(CONTROLE), str(ipa)],
        capture_output=True,
        text=True,
    )
    return resultat.returncode, resultat.stdout + resultat.stderr


def main() -> int:
    echecs: list[str] = []
    reussites = 0

    with tempfile.TemporaryDirectory(prefix="ipa-temoin-") as brut:
        ipa = fabriquer_ipa(
            Path(brut),
            plateforme_plist="iphoneos",
            supportees=["iPhoneOS"],
            plateforme_macho=2,
            avec_temoins=True,
        )
        code, sortie = lancer(ipa)
        if code == 0:
            reussites += 1
            print("  ok    temoin : faux IPA d'appareil accepte (code 0)")
        else:
            echecs.append(f"temoin : code {code}, attendu 0\n{sortie}")
            print("  KO    temoin : refusé alors qu'il devait passer")

    for nom, parametres, fragments in CAS:
        with tempfile.TemporaryDirectory(prefix="ipa-") as brut:
            ipa = fabriquer_ipa(Path(brut), **parametres)
            code, sortie = lancer(ipa)
            manquants = [f for f in fragments if f not in sortie]
            if code == 1 and not manquants:
                reussites += 1
                print(f"  ok    {nom} -> refuse, et pour la bonne raison")
            elif code == 0:
                echecs.append(f"{nom} : ACCEPTE alors qu'il devait etre refuse")
                print(f"  KO    {nom} : accepte (resté vert)")
            else:
                echecs.append(f"{nom} : refuse, mais sans {manquants}\n{sortie}")
                print(f"  KO    {nom} : refuse sans {manquants}")

    print(f"\n{reussites} cas vert(s), {len(echecs)} echec(s).")
    if echecs:
        print("\nEchecs :")
        for echec in echecs:
            print(f"  - {echec}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
