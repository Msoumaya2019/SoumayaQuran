#!/usr/bin/env python3
"""Banc du controle `verifier_flux.py` — un controle jamais falsifie ne vaut rien.

Un controle qui passe ne prouve pas qu'il regarde quelque chose. Chaque cas
ci-dessous introduit un defaut reel dans une **copie temporaire** des vrais
flux, puis exige du controle :

  * le code de sortie 1 ;
  * **et** le marqueur attendu dans sa sortie.

Le marqueur compte autant que le code : un echec pour une autre raison ne
prouve rien. Chaque marqueur est en ASCII, pour que l'assertion ne depende ni de
l'encodage ni de la reformulation d'une phrase.

Deux disciplines que le banc tient :

  * il ne mute **jamais** les fichiers reels — il travaille sur une copie. Un
    banc qui sauvegarde puis restaure abime ce qu'il touche, parce que
    `write_text` traduit `\n` en `\\r\\n` sous Windows, et la restauration est
    fidele au caractere pres, pas a l'octet pres ;
  * il **compte les occurrences** de chaque ancre et exige exactement 1. Une
    ancre courte trouve toujours du texte en position d'infixe — `on:` apparait
    aussi dans `runs-on:` — et une mutation appliquee au mauvais endroit fait
    croire que le controle est aveugle alors qu'il n'a rien eu a examiner.

Il distingue aussi « motif introuvable » de « reste vert » : les deux donnent un
message different, sans quoi on cherche le defaut du mauvais cote.

Usage : python tools/banc_verifier_flux.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
REEL = RACINE / ".github" / "workflows"
CONTROLE = RACINE / "tools" / "verifier_flux.py"

FLUX_MINIMAL_VALIDE = """\
name: autre
on:
  workflow_dispatch:
permissions:
  contents: read
jobs:
  rien:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
"""


class AncreIntrouvable(Exception):
    """L'ancre ne correspond pas : la mutation n'a pas eu lieu."""


def remplacer(texte: str, ancre: str, remplacement: str) -> str:
    """Remplace une ancre, en exigeant qu'elle soit unique."""
    compte = texte.count(ancre)
    if compte != 1:
        raise AncreIntrouvable(f"ancre trouvee {compte} fois, 1 attendue : {ancre!r}")
    return texte.replace(ancre, remplacement)


def supprimer(texte: str, ancre: str) -> str:
    return remplacer(texte, ancre, "")


def copier_les_vrais_flux(dossier: Path) -> None:
    # Un fichier par un fichier : `copytree` d'un dossier vers un dossier
    # existant a un comportement ambigu selon la version de Python.
    for chemin in sorted(REEL.iterdir()):
        if chemin.is_file():
            shutil.copyfile(chemin, dossier / chemin.name)


def lancer(dossier: Path) -> tuple[int, str]:
    resultat = subprocess.run(
        [sys.executable, "-u", str(CONTROLE), str(dossier)],
        capture_output=True,
        text=True,
    )
    return resultat.returncode, resultat.stdout + resultat.stderr


# --- Les mutations ---------------------------------------------------------
#
# Chaque entree rend le texte mute. Les cas qui portent sur la PRESENCE d'un
# fichier sont traites a part : aucune mutation de texte ne peut les produire.

def mutation_yaml_invalide(texte: str) -> str:
    return remplacer(texte, "name: build\n", "name: [build\n")


def mutation_script_invalide(texte: str) -> str:
    # Un `if` sans `fi` : `bash -n` le refuse, le flux echouerait apres
    # l'installation complete.
    return remplacer(
        texte,
        "      - name: Taille de l'APK\n        run: ls -lh",
        "      - name: Taille de l'APK\n        run: if [ -z \"$X\" ]; then echo 1",
    )


def mutation_permissions_absentes(texte: str) -> str:
    return supprimer(texte, "permissions:\n  contents: read\n")


def mutation_action_non_epinglee(texte: str) -> str:
    # Ancre longue : `actions/upload-artifact@v7` apparait deux fois (Android et
    # iOS), et le banc exige une occurrence unique.
    return remplacer(
        texte,
        "actions/upload-artifact@v7\n        with:\n          name: soumaya-apk",
        "actions/upload-artifact\n        with:\n          name: soumaya-apk",
    )


def mutation_declencheur_absent(texte: str) -> str:
    return remplacer(texte, "\non:\n", "\ndeclencheurs:\n")


def mutation_runs_on_absent(texte: str) -> str:
    return supprimer(texte, "    runs-on: macos-latest\n")


def mutation_permissions_insuffisantes(texte: str) -> str:
    # Un job qui publie une version a besoin de `contents: write` effectif. Le
    # defaut ne se manifeste qu'a la derniere etape, apres une compilation
    # entiere — et le message parle de permissions, pas de la compilation.
    return remplacer(
        texte,
        "      - name: Empaqueter l'IPA\n",
        "      - name: Publier la version\n        run: gh release create v0 --notes x\n\n"
        "      - name: Empaqueter l'IPA\n",
    )


def mutation_sortie_inconnue(texte: str) -> str:
    return remplacer(
        texte,
        '          echo "Version lue dans pubspec.yaml : $VERSION"\n',
        '          echo "Version lue dans pubspec.yaml : $VERSION"\n'
        '          echo "inconnu=${{ steps.inexistant.outputs.quoi }}"\n',
    )


def mutation_etape_vide(texte: str) -> str:
    return remplacer(
        texte,
        "      - run: flutter pub get\n\n      # Le numéro de version vit",
        "      - name: Etape sans effet\n\n      # Le numéro de version vit",
    )


def mutation_expression_non_fermee(texte: str) -> str:
    return remplacer(
        texte,
        "          flutter-version: ${{ env.FLUTTER_VERSION }}\n          channel: stable\n"
        "          cache: true\n\n      # Journalise la chaîne Apple",
        "          flutter-version: ${{ env.FLUTTER_VERSION }\n          channel: stable\n"
        "          cache: true\n\n      # Journalise la chaîne Apple",
    )


CAS_DE_TEXTE = [
    ("yaml-invalide", "[yaml-invalide]", mutation_yaml_invalide),
    ("script refuse par bash -n", "[script-invalide]", mutation_script_invalide),
    ("permissions absentes", "[permissions-absentes]", mutation_permissions_absentes),
    ("action non epinglee", "[action-non-epinglee]", mutation_action_non_epinglee),
    ("declencheur absent", "[declencheur-absent]", mutation_declencheur_absent),
    ("runs-on absent", "[runs-on-absent]", mutation_runs_on_absent),
    (
        "permissions insuffisantes pour publier",
        "[permissions-insuffisantes]",
        mutation_permissions_insuffisantes,
    ),
    ("sortie inconnue", "[sortie-inconnue]", mutation_sortie_inconnue),
    ("etape vide", "[etape-vide]", mutation_etape_vide),
    ("expression non fermee", "[expression-non-fermee]", mutation_expression_non_fermee),
]


def main() -> int:
    if not REEL.is_dir():
        print(f"dossier reel introuvable : {REEL}", file=sys.stderr)
        return 2

    texte_reel = (REEL / "build.yml").read_text(encoding="utf-8")
    echecs: list[str] = []
    reussites = 0

    # --- Le temoin. Sans lui, un controle qui refuserait TOUTE copie passerait
    # --- pour concluant, et tous les cas suivants seraient verts pour la
    # --- mauvaise raison.
    with tempfile.TemporaryDirectory(prefix="flux-temoin-") as brut:
        dossier = Path(brut)
        copier_les_vrais_flux(dossier)
        code, sortie = lancer(dossier)
        if code == 0 and "Aucun defaut" in sortie:
            reussites += 1
            print("  ok    temoin : copie intacte acceptee (code 0)")
        else:
            echecs.append(f"temoin : code {code}, sortie inattendue\n{sortie}")

    # --- Les mutations de texte.
    for nom, marqueur, mutation in CAS_DE_TEXTE:
        with tempfile.TemporaryDirectory(prefix="flux-") as brut:
            dossier = Path(brut)
            copier_les_vrais_flux(dossier)
            try:
                mute = mutation(texte_reel)
            except AncreIntrouvable as erreur:
                echecs.append(f"{nom} : MUTATION NON APPLIQUEE — {erreur}")
                print(f"  KO    {nom} : mutation non appliquee")
                continue
            if mute == texte_reel:
                echecs.append(f"{nom} : MUTATION SANS EFFET (texte identique)")
                print(f"  KO    {nom} : mutation sans effet")
                continue
            (dossier / "build.yml").write_text(mute, encoding="utf-8", newline="\n")

            code, sortie = lancer(dossier)
            if code == 1 and marqueur in sortie:
                reussites += 1
                print(f"  ok    {nom} -> {marqueur}")
            elif code == 0:
                echecs.append(f"{nom} : RESTE VERT, {marqueur} attendu")
                print(f"  KO    {nom} : reste vert ({marqueur} attendu)")
            else:
                echecs.append(f"{nom} : refuse, mais sans {marqueur}\n{sortie}")
                print(f"  KO    {nom} : refuse sans {marqueur}")

    # --- La presence d'un fichier. Aucune mutation de texte ne peut produire
    # --- ces deux cas : ils portent sur le contenu du dossier lui-meme.
    with tempfile.TemporaryDirectory(prefix="flux-absent-") as brut:
        dossier = Path(brut)
        copier_les_vrais_flux(dossier)
        (dossier / "build.yml").unlink()
        code, sortie = lancer(dossier)
        if code == 1 and "[flux-absent]" in sortie and "build.yml" in sortie:
            reussites += 1
            print("  ok    flux attendu retire -> [flux-absent]")
        else:
            echecs.append(f"flux retire : code {code}, sortie inattendue\n{sortie}")
            print("  KO    flux attendu retire")

    with tempfile.TemporaryDirectory(prefix="flux-non-declare-") as brut:
        dossier = Path(brut)
        copier_les_vrais_flux(dossier)
        (dossier / "autre.yml").write_text(
            FLUX_MINIMAL_VALIDE, encoding="utf-8", newline="\n"
        )
        code, sortie = lancer(dossier)
        if code == 1 and "[flux-non-declare]" in sortie and "autre.yml" in sortie:
            reussites += 1
            print("  ok    flux valide ajoute non declare -> [flux-non-declare]")
        else:
            echecs.append(
                f"flux ajoute : code {code}, sortie inattendue — le flux minimal "
                f"doit etre VALIDE, sinon le refus viendrait d'ailleurs\n{sortie}"
            )
            print("  KO    flux valide ajoute non declare")

    print(f"\n{reussites} cas vert(s), {len(echecs)} echec(s).")
    if echecs:
        print("\nEchecs :")
        for echec in echecs:
            print(f"  - {echec}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
