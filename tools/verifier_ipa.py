#!/usr/bin/env python3
"""Verifie le contenu d'un IPA livre, sans Mac et sans appareil.

Pourquoi ce fichier existe
--------------------------
Une compilation verte ne dit pas ce que le binaire contient. Deux defauts
passent un build reussi et ne se voient qu'apres installation :

  * **une compilation de SIMULATEUR.** Elle a exactement la forme d'un IPA et
    ne s'installera sur aucun iPhone, meme signee. Rien dans la taille du
    fichier ne le dit ;
  * **un binaire qui ne porte pas le code attendu** — une compilation d'un
    autre commit, ou un code Dart absent du binaire.

Le controle porte donc sur ce que le fichier DIT, pas sur le fait qu'il existe.

Les trois temoins de plateforme, tous independants
--------------------------------------------------
  1. `Info.plist` -> `DTPlatformName` : `iphoneos` ou `iphonesimulator` ;
  2. `Info.plist` -> `CFBundleSupportedPlatforms` : `['iPhoneOS']` ou
     `['iPhoneSimulator']` ;
  3. l'en-tete Mach-O, commande de chargement `LC_BUILD_VERSION`, champ
     `platform` : 1 macOS, 2 iOS (appareil), 6 macCatalyst, 7 iOSSimulator.

Les lire tous les trois : ils sont independants, et l'un peut manquer selon la
forme du fichier.

Attention a un faux ami : **l'absence de `embedded.mobileprovision` ne prouve
pas** qu'on a affaire a une compilation pour appareil. Une compilation
`-sdk iphoneos` non signee en est depourvue elle aussi. Ce temoin dit « pas
signe », il ne dit pas « pour appareil ».

Usage
-----
    python tools/verifier_ipa.py chemin/vers/fichier.ipa

Code de sortie 0 si le fichier passe les controles bloquants, 1 sinon.
"""

from __future__ import annotations

import plistlib
import re
import struct
import sys
import zipfile
from pathlib import Path

# Plateformes du champ `platform` de LC_BUILD_VERSION.
PLATEFORMES = {1: "macOS", 2: "iOS (appareil)", 6: "macCatalyst", 7: "iOSSimulator"}

# LC_BUILD_VERSION
LC_BUILD_VERSION = 0x32

# Chaines cherchees dans l'instantane Dart. Elles viennent du code source du
# projet : leur presence etablit que le binaire porte bien ce code-la.
TEMOINS_DART = [
    "apis.quran.foundation",
    "verses.quran.foundation",
    "snapshots/mushafs",
    "by_page",
]

defauts: list[str] = []
verifications = 0


def verifier(condition: bool, message: str) -> None:
    global verifications
    verifications += 1
    if not condition:
        defauts.append(message)


def tranches_macho(donnees: bytes) -> list[tuple[str, int]]:
    """Rend (nom de tranche, plateforme) pour chaque tranche du binaire.

    Un binaire peut etre mince ou epais : les deux formes sont parcourues.
    Sur un binaire epais, les tranches peuvent se contredire — c'est pourquoi
    on les lit toutes au lieu de s'arreter a la premiere.
    """
    if len(donnees) < 8:
        return []

    (magie,) = struct.unpack_from(">I", donnees, 0)
    resultats: list[tuple[str, int]] = []

    if magie == 0xCAFEBABE:  # binaire epais, en-tete gros-boutiste
        (nfat,) = struct.unpack_from(">I", donnees, 4)
        for index in range(nfat):
            base = 8 + index * 20
            cputype, _cpusubtype, offset, size, _align = struct.unpack_from(
                ">IIIII", donnees, base
            )
            tranche = donnees[offset : offset + size]
            plateforme = _plateforme_de_tranche(tranche)
            resultats.append((f"tranche {index} (cputype {cputype})", plateforme))
        return resultats

    return [("binaire mince", _plateforme_de_tranche(donnees))]


def _plateforme_de_tranche(tranche: bytes) -> int:
    """Rend le numero de plateforme, ou -1 si LC_BUILD_VERSION est absente."""
    if len(tranche) < 32:
        return -1
    (magie,) = struct.unpack_from("<I", tranche, 0)
    if magie == 0xFEEDFACF:  # 64 bits
        position = 32
    elif magie == 0xFEEDFACE:  # 32 bits
        position = 28
    else:
        return -1

    (ncmds,) = struct.unpack_from("<I", tranche, 16)
    for _ in range(ncmds):
        if position + 8 > len(tranche):
            return -1
        cmd, cmdsize = struct.unpack_from("<II", tranche, position)
        if cmdsize == 0:
            return -1
        if cmd == LC_BUILD_VERSION:
            (plateforme,) = struct.unpack_from("<I", tranche, position + 8)
            return plateforme
        position += cmdsize
    return -1


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-3].strip(), file=sys.stderr)
        print("usage : python tools/verifier_ipa.py fichier.ipa", file=sys.stderr)
        return 2

    ipa = Path(sys.argv[1])
    if not ipa.is_file():
        print(f"fichier introuvable : {ipa}", file=sys.stderr)
        return 2

    print(f"Fichier : {ipa.name}")
    print(f"Taille  : {ipa.stat().st_size} octets\n")

    verifier(zipfile.is_zipfile(ipa), "Le fichier n'est pas une archive ZIP valide.")

    with zipfile.ZipFile(ipa) as archive:
        noms = archive.namelist()

        # Un IPA est une archive ZIP dont la racine porte Payload/<App>.app.
        apps = sorted({n.split("/")[1] for n in noms if n.startswith("Payload/") and len(n.split("/")) > 2})
        verifier(
            len(apps) == 1,
            f"La racine Payload/ doit porter exactement une application, "
            f"trouve {len(apps)} : {apps}",
        )
        if not apps:
            print("Aucune application sous Payload/ : le reste ne peut pas etre verifie.")
            return 1

        nom_app = apps[0]
        racine = f"Payload/{nom_app}"
        print(f"Application : {nom_app}\n")

        # --- L'Info.plist.
        with archive.open(f"{racine}/Info.plist") as flux:
            plist = plistlib.load(flux)

        plateforme = plist.get("DTPlatformName", "?")
        supportees = plist.get("CFBundleSupportedPlatforms", [])
        identifiant = plist.get("CFBundleIdentifier", "?")
        executable = plist.get("CFBundleExecutable", "?")
        minimum = plist.get("MinimumOSVersion", "?")
        version = plist.get("CFBundleShortVersionString", "?")
        build = plist.get("CFBundleVersion", "?")

        print("Info.plist")
        print(f"  DTPlatformName             = {plateforme}")
        print(f"  CFBundleSupportedPlatforms = {supportees}")
        print(f"  CFBundleIdentifier         = {identifiant}")
        print(f"  CFBundleExecutable         = {executable}")
        print(f"  MinimumOSVersion           = {minimum}")
        print(f"  Version                    = {version} ({build})\n")

        verifier(
            plateforme == "iphoneos",
            f"DTPlatformName vaut {plateforme} : ce n'est pas une compilation pour "
            f"appareil, elle ne s'installera sur aucun iPhone, meme signee.",
        )
        verifier(
            supportees == ["iPhoneOS"],
            f"CFBundleSupportedPlatforms vaut {supportees}, attendu ['iPhoneOS'].",
        )

        # --- La signature. Deux temoins distincts.
        signatures = [n for n in noms if n.startswith(f"{racine}/_CodeSignature/")]
        profils = [n for n in noms if n.endswith("embedded.mobileprovision")]
        print("Signature")
        print(f"  entrees _CodeSignature/    = {len(signatures)}")
        print(f"  embedded.mobileprovision   = {'present' if profils else 'absent'}")
        if not profils:
            print("  -> non signe. Ce temoin ne dit PAS si la compilation vise un appareil :")
            print("     une compilation iphoneos non signee est depourvue de profil elle aussi.")
        print()

        # --- Le binaire, tranche par tranche.
        binaire = f"{racine}/{executable}"
        verifier(binaire in noms, f"L'executable {executable} est absent du paquet.")
        if binaire in noms:
            donnees = archive.read(binaire)
            print(f"Mach-O ({executable}, {len(donnees)} octets)")
            tranches = tranches_macho(donnees)
            verifier(bool(tranches), "Aucune tranche Mach-O lisible.")
            for nom, numero in tranches:
                libelle = PLATEFORMES.get(numero, f"inconnue ({numero})")
                print(f"  {nom} : platform = {numero} -> {libelle}")
                verifier(
                    numero != 7,
                    f"{nom} declare iOSSimulator : binaire de simulateur, "
                    f"ininstallable sur un appareil.",
                )
                verifier(
                    numero == 2,
                    f"{nom} ne declare pas iOS (appareil) mais {libelle}.",
                )
            print()

        # --- L'instantane Dart.
        # L'emplacement n'est pas garanti : on cherche, au lieu de supposer.
        candidats = [
            n
            for n in noms
            if n.endswith("/App.framework/App") or n.endswith("/App.framework/App.framework")
        ]
        print("Code Dart embarque")
        if not candidats:
            print("  Instantane introuvable — releve impossible. Candidats proches :")
            for n in noms:
                if "App.framework" in n and not n.endswith("/"):
                    print(f"    {n}")
        else:
            for candidat in candidats:
                contenu = archive.read(candidat)
                print(f"  {candidat} ({len(contenu)} octets)")
                trouves = 0
                for temoin in TEMOINS_DART:
                    compte = len(re.findall(re.escape(temoin.encode()), contenu))
                    print(f"    {temoin} : {compte} occurrence(s)")
                    trouves += 1 if compte else 0
                verifier(
                    trouves == len(TEMOINS_DART),
                    f"{trouves} temoin(s) Dart sur {len(TEMOINS_DART)} retrouves dans "
                    f"{candidat} : le binaire ne porte pas le code attendu.",
                )
        print()

    print(f"{verifications} verification(s).")
    if defauts:
        print(f"\n{len(defauts)} defaut(s) bloquant(s) :")
        for defaut in defauts:
            print(f"  - {defaut}")
        return 1

    print("Le fichier est un IPA de compilation POUR APPAREIL, non signe.")
    print("Il se re-signe (Sideloadly, AltStore, eSign), puis s'installe.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
