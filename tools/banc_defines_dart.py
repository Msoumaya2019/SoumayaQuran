#!/usr/bin/env python3
"""Banc du controle `defines_dart.py` — un controle jamais falsifie ne vaut rien.

Ce que ce banc eprouve, et pourquoi il est different du banc des flux
---------------------------------------------------------------------
Le banc des flux mute du TEXTE et regarde si un analyseur s'en apercoit. Ici il
n'y a rien a analyser : le controle *est* un programme. On l'execute donc, dans
un environnement fabrique, et on regarde ce qu'il rend. C'est plus fort — aucune
reformulation ne peut faire passer un resultat faux — mais cela impose deux
disciplines :

  * l'environnement du sous-processus est **fabrique**, jamais herite. Sans
    cela, un `GITHUB_STEP_SUMMARY` ou un `SOUMAYA_PROXY_BASE_URL` present sur la
    machine d'essai changerait le resultat, et le banc serait vert en local,
    rouge en CI, ou l'inverse ;
  * le code de sortie **et** la sortie sont lus ensemble. Un script qui echoue
    pour une autre raison que celle attendue ne prouve rien.

Le cas qui compte le plus est celui de la variable absente : c'est le defaut
reel de ce depot, celui que la CI livrait. Un controle qui n'exigerait que
« pas d'erreur » le laisserait passer.

Usage
-----
    python tools/banc_defines_dart.py
    python tools/banc_defines_dart.py --falsifier
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
CONTROLE = RACINE / "tools" / "defines_dart.py"

TOUTES = ("SOUMAYA_PROXY_BASE_URL", "SOUMAYA_QF_CLIENT_ID", "SOUMAYA_QCF_FONT_BASE_URL")

MARQUEUR_VALEUR_INVALIDE = "[valeur-invalide]"


class AncreIntrouvable(Exception):
    """L'ancre ne correspond pas : la mutation n'a pas eu lieu."""


def remplacer(texte: str, ancre: str, remplacement: str) -> str:
    compte = texte.count(ancre)
    if compte != 1:
        raise AncreIntrouvable(f"ancre trouvee {compte} fois, 1 attendue : {ancre!r}")
    return texte.replace(ancre, remplacement)


class Resultat:
    def __init__(self, code: int, sortie: str, erreur: str, resume: str) -> None:
        self.code = code
        self.sortie = sortie
        self.erreur = erreur
        self.resume = resume

    @property
    def definis(self) -> list[str]:
        return [mot for mot in self.sortie.split() if mot.startswith("--dart-define=")]


def environnement(**variables: str) -> dict[str, str]:
    """Un environnement minimal, plus ce que le cas veut y mettre.

    `SYSTEMROOT` est conserve sous Windows : sans lui, l'interpreteur lui-meme
    peut refuser de demarrer, et l'echec viendrait de l'essai, pas du controle.
    """
    base = {
        "PYTHONIOENCODING": "utf-8",
        "SYSTEMROOT": os.environ.get("SYSTEMROOT", ""),
        "PATH": os.environ.get("PATH", ""),
    }
    base.update(variables)
    return base


def lancer(controle: Path, variables: dict[str, str], resume: Path | None = None) -> Resultat:
    env = environnement(**variables)
    if resume is not None:
        env["GITHUB_STEP_SUMMARY"] = str(resume)
    resultat = subprocess.run(
        [sys.executable, "-u", str(controle)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )
    # Le fichier de resume n'existe pas tant que personne n'y ecrit : GitHub le
    # cree avant l'etape, mais rien ne l'exige. Absent et vide disent la meme
    # chose — « rien n'a ete ecrit » — et le banc les traite pareil.
    contenu = resume.read_text(encoding="utf-8") if resume is not None and resume.exists() else ""
    return Resultat(resultat.returncode, resultat.stdout, resultat.stderr, contenu)


# --- Les cas ---------------------------------------------------------------
#
# Chaque cas rend la liste des reproches. Liste vide : le cas est vert.


def cas_temoin(controle: Path, dossier: Path) -> list[str]:
    """Les trois renseignees : les trois passent, dans l'ordre declare."""
    resume = dossier / "resume-temoin.md"
    valeurs = {
        "SOUMAYA_PROXY_BASE_URL": "https://proxy.exemple.fr",
        "SOUMAYA_QF_CLIENT_ID": "client-123",
        "SOUMAYA_QCF_FONT_BASE_URL": "https://polices.exemple.fr",
    }
    resultat = lancer(controle, valeurs, resume)

    reproches: list[str] = []
    if resultat.code != 0:
        reproches.append(f"code {resultat.code}, 0 attendu\n{resultat.erreur}")
    attendus = [f"--dart-define={nom}={valeur}" for nom, valeur in valeurs.items()]
    if resultat.definis != attendus:
        reproches.append(f"definitions {resultat.definis}, attendu {attendus}")
    if "::warning::" in resultat.erreur:
        reproches.append("avertissement alors que tout est renseigne")
    if resultat.resume != "":
        reproches.append(f"resume ecrit alors que rien ne manque : {resultat.resume!r}")
    return reproches


def cas_aucune_renseignee(controle: Path, dossier: Path) -> list[str]:
    """Le cas du depot : rien n'est renseigne, donc rien ne doit etre passe.

    C'est ici que se joue le defaut reel. Un `--dart-define=X=` produit par
    cette situation vide la valeur par defaut du code, et la compilation reste
    verte : personne ne s'en apercevrait avant l'execution.
    """
    resume = dossier / "resume-vide.md"
    resultat = lancer(controle, {}, resume)

    reproches: list[str] = []
    if resultat.code != 0:
        reproches.append(f"code {resultat.code}, 0 attendu\n{resultat.erreur}")
    if resultat.definis:
        reproches.append(
            f"a passe {resultat.definis} alors que rien n'est renseigne — "
            "un --dart-define vide l'emporte sur le defaultValue du code"
        )
    if "::warning::" not in resultat.erreur:
        reproches.append("aucun avertissement : la CI compilerait en silence")
    for nom in TOUTES:
        if nom not in resultat.erreur:
            reproches.append(f"l'avertissement ne nomme pas {nom}")
    if resultat.resume.strip() == "":
        reproches.append("aucun resume ecrit alors que les trois manquent")
    for nom in TOUTES:
        if nom not in resultat.resume:
            reproches.append(f"le resume ne nomme pas {nom}")
    return reproches


def cas_une_seule(controle: Path, dossier: Path) -> list[str]:
    """Une seule renseignee : une seule definition, et la bonne."""
    resultat = lancer(controle, {"SOUMAYA_QF_CLIENT_ID": "client-seul"})

    reproches: list[str] = []
    if resultat.code != 0:
        reproches.append(f"code {resultat.code}, 0 attendu\n{resultat.erreur}")
    attendus = ["--dart-define=SOUMAYA_QF_CLIENT_ID=client-seul"]
    if resultat.definis != attendus:
        reproches.append(f"definitions {resultat.definis}, attendu {attendus}")
    for nom in ("SOUMAYA_PROXY_BASE_URL", "SOUMAYA_QCF_FONT_BASE_URL"):
        if nom not in resultat.erreur:
            reproches.append(f"aucun avertissement pour {nom}")
    if "SOUMAYA_QF_CLIENT_ID est vide" in resultat.erreur:
        reproches.append("avertit sur une variable qui est renseignee")
    return reproches


def cas_renseignee_a_vide(controle: Path, dossier: Path) -> list[str]:
    """Renseignee a vide et absente sont le meme cas — et doivent le rester."""
    resultat = lancer(controle, {"SOUMAYA_PROXY_BASE_URL": "", "SOUMAYA_QF_CLIENT_ID": "c"})

    reproches: list[str] = []
    if resultat.code != 0:
        reproches.append(f"code {resultat.code}, 0 attendu\n{resultat.erreur}")
    attendus = ["--dart-define=SOUMAYA_QF_CLIENT_ID=c"]
    if resultat.definis != attendus:
        reproches.append(f"definitions {resultat.definis}, attendu {attendus}")
    return reproches


def cas_valeur_a_blanc(controle: Path, dossier: Path) -> list[str]:
    """Une valeur qui contient un blanc casserait la ligne de commande.

    Le shell la decouperait en plusieurs arguments et `flutter build` recevrait
    une option tronquee sans le dire. Le refus est la seule issue honnete — et
    il ne doit rien laisser passer sur la sortie standard.
    """
    resultat = lancer(controle, {"SOUMAYA_QF_CLIENT_ID": "deux mots"})

    reproches: list[str] = []
    if resultat.code != 1:
        reproches.append(f"code {resultat.code}, 1 attendu")
    if MARQUEUR_VALEUR_INVALIDE not in resultat.erreur:
        reproches.append(f"marqueur {MARQUEUR_VALEUR_INVALIDE} absent de : {resultat.erreur!r}")
    if resultat.definis:
        reproches.append(f"a quand meme passe {resultat.definis}")
    return reproches


CAS = [
    ("temoin — les trois renseignees", cas_temoin),
    ("aucune renseignee — le cas du depot", cas_aucune_renseignee),
    ("une seule renseignee", cas_une_seule),
    ("renseignee a vide", cas_renseignee_a_vide),
    ("valeur contenant un blanc", cas_valeur_a_blanc),
]


def executer(controle: Path, verbeux: bool = True) -> list[str]:
    echecs: list[str] = []
    with tempfile.TemporaryDirectory(prefix="defines-") as brut:
        dossier = Path(brut)
        for nom, cas in CAS:
            try:
                reproches = cas(controle, dossier)
            except AncreIntrouvable as erreur:  # pragma: no cover - garde-fou
                reproches = [str(erreur)]
            if reproches:
                echecs.append(f"{nom} : " + " ; ".join(reproches))
                if verbeux:
                    print(f"  KO    {nom}")
            elif verbeux:
                print(f"  ok    {nom}")
    return echecs


# --- La falsification ------------------------------------------------------
#
# Un banc vert ne prouve rien tant qu'on ne l'a pas vu rougir. Ces mutations
# sont celles du defaut reel et de sa variante : si le banc ne les attrape pas,
# c'est le banc qui est faux, pas le controle.

def mutation_plus_de_vide_ecarte(texte: str) -> str:
    """Le defaut d'origine : les vides sont passes comme les autres."""
    return remplacer(texte, 'if valeur == "":', "if False:")


def mutation_plus_de_blanc_refuse(texte: str) -> str:
    """La commande cassee : le refus disparait, l'option part tronquee."""
    return remplacer(
        texte,
        "if any(blanc in valeur for blanc in BLANCS):",
        "if False:",
    )


def mutation_resume_muet(texte: str) -> str:
    """Le resume ne dit plus ce qui manque : la CI compile en silence."""
    return remplacer(texte, "if not manquantes:", "if True:")


MUTATIONS = [
    ("les valeurs vides sont passees", mutation_plus_de_vide_ecarte),
    ("les valeurs a blanc ne sont plus refusees", mutation_plus_de_blanc_refuse),
    ("le resume ne dit plus rien", mutation_resume_muet),
]


def falsifier() -> int:
    texte = CONTROLE.read_text(encoding="utf-8")
    echecs: list[str] = []

    with tempfile.TemporaryDirectory(prefix="defines-faux-") as brut:
        dossier = Path(brut)
        temoin = dossier / "controle_intact.py"
        temoin.write_text(texte, encoding="utf-8", newline="\n")
        reproches = executer(temoin, verbeux=False)
        if reproches:
            echecs.append(
                "la copie intacte est refusee par le banc — le banc est faux : "
                + " ; ".join(reproches)
            )
            print("  KO    copie intacte : le banc la refuse")
        else:
            print("  ok    copie intacte acceptee (le banc ne rougit pas pour rien)")

        for nom, mutation in MUTATIONS:
            try:
                mute = mutation(texte)
            except AncreIntrouvable as erreur:
                echecs.append(f"{nom} : MUTATION NON APPLIQUEE — {erreur}")
                print(f"  KO    {nom} : mutation non appliquee")
                continue
            if mute == texte:
                echecs.append(f"{nom} : MUTATION SANS EFFET")
                print(f"  KO    {nom} : mutation sans effet")
                continue
            faux = dossier / "controle_mute.py"
            faux.write_text(mute, encoding="utf-8", newline="\n")
            reproches = executer(faux, verbeux=False)
            if reproches:
                print(f"  ok    {nom} -> detecte ({len(reproches)} cas rouge(s))")
            else:
                echecs.append(f"{nom} : LE BANC RESTE VERT sur un controle faux")
                print(f"  KO    {nom} : le banc reste vert")

    print(f"\n{len(MUTATIONS) + 1 - len(echecs)} falsification(s) concluante(s), {len(echecs)} echec(s).")
    if echecs:
        print("\nEchecs :")
        for echec in echecs:
            print(f"  - {echec}")
        return 1
    return 0


def main(argv: list[str]) -> int:
    if "--falsifier" in argv:
        return falsifier()

    if not CONTROLE.is_file():
        print(f"controle introuvable : {CONTROLE}", file=sys.stderr)
        return 2

    echecs = executer(CONTROLE)
    print(f"\n{len(CAS) - len(echecs)} cas vert(s), {len(echecs)} echec(s).")
    if echecs:
        print("\nEchecs :")
        for echec in echecs:
            print(f"  - {echec}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
