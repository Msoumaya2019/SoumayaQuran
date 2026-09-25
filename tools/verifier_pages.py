#!/usr/bin/env python3
"""Verifie les pages publiees du dossier `docs/` : structure, marqueurs, liens.

Pourquoi ce fichier existe
--------------------------
Ces pages sont la contrepartie exigee par les Developer Terms de la Quran
Foundation — « Provide a publicly reachable Privacy Policy and Terms of Use ».
Elles sont lues hors de l'application, par un tiers, et rien dans la chaine
habituelle ne signale qu'elles sont cassees : elles ne compilent pas, elles ne
sont pas testees, et GitHub Pages publie un fichier mal forme sans broncher.

Trois defauts, tous mesures, que ce controle attrape :

  * un lien interne ecrit en ABSOLU. Le site est un site de PROJET, servi sous
    `…github.io/<depot>/` : `href="/terms/"` vise la racine du DOMAINE, donc
    `…github.io/terms/` -> 404. La cible existait, le controle de presence la
    voyait, et la page etait morte ;
  * un marqueur `{{RESPONSABLE}}` reste dans le TEXTE AFFICHE : la page publiee
    perd son contact en silence. La recherche porte donc sur le texte RENDU et
    non sur le source — un marqueur laisse dans un commentaire HTML ne
    s'affiche pas, et une recherche dans le fichier entier le declare present ;
  * une balise mal imbriquee. Compter les balises ne le voit pas : on empile les
    ouvrantes, et chaque fermante doit refermer la derniere ouverte.

Portee — et un controle de couverture doit dire ou il s'arrete
--------------------------------------------------------------
ATTRAPE : balise mal imbriquee ou jamais fermee, `</x>` orphelin, marqueur non
rempli dans le texte affiche, coordonnees exigees absentes du texte affiche,
lien interne absolu, page attendue absente, page presente mais non declaree,
lien croise manquant, phrase de fond absente, `<title>` ou `lang` absents.

N'ATTRAPE PAS : une page visuellement fausse (CSS, contraste, lisibilite) ; une
phrase juridiquement insuffisante, qui releve de `verifier_conformite.py` ; une
page injoignable EN LIGNE, qui se mesure par le reseau ; une cible EXTERNE morte
(quran.com, quranreflect.com), qui depend d'un tiers.

Usage
-----
    python tools/verifier_pages.py [racine]

`racine` vise une COPIE temporaire, pour que le banc falsifie ce controle sans
jamais muter les vrais fichiers : un banc qui sauvegarde puis restaure abime ce
qu'il touche (`write_text` traduit `\\n` en `\\r\\n` sous Windows). Defaut : la
racine du depot.

Code de sortie 0 si aucun defaut, 1 sinon. Chaque defaut porte un marqueur ASCII
entre crochets, pour qu'un banc puisse s'y accrocher sans dependre de l'encodage
ni de la reformulation d'une phrase.
"""

from __future__ import annotations

import re
import sys
from html.parser import HTMLParser
from pathlib import Path

RACINE_DEFAUT = Path(__file__).resolve().parent.parent

# Liste FERMEE : ce controle est le seul lecteur du dossier publie. Sans liste
# fermee, il mesure ce qui reste et jamais ce qui manque, et une page disparue
# produirait un vert trompeur. Une page ajoutee doit donc etre declaree ici.
#
# nom -> (chemin relatif a `docs/`, coordonnees qui doivent etre LISIBLES)
PAGES = {
    "accueil": ("index.html", ()),
    "confidentialite": (
        "privacy/index.html",
        ("Mohamed C", "Avenue Gallieni", "93200 St Denis", "axox93@hotmail.fr"),
    ),
    "conditions": (
        "terms/index.html",
        ("Mohamed C", "Avenue Gallieni", "axox93@hotmail.fr"),
    ),
}

# Liens internes attendus, par page, ecrits RELATIFS. Un lien absolu vise la
# racine du domaine : voir l'en-tete.
LIENS_ATTENDUS = {
    "accueil": ("privacy/", "terms/"),
    "confidentialite": ("../terms/",),
    "conditions": ("../privacy/",),
}

# Phrases qui ne peuvent venir que du document, et qui portent une obligation
# des Developer Terms. Sans elles, une page videe de son fond passerait pour
# saine des lors que sa structure et ses liens tiennent.
PHRASES_ATTENDUES = {
    "confidentialite": ("TLS 1.2", "developers@quran.com", "Security Rule 6.9"),
    "conditions": ("n'est en aucune façon modifié", "droit français"),
}

# Elements sans contenu : ils ne s'empilent pas et n'attendent pas de fermante.
VIDES = {
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
}

verifications = 0
defauts: list[str] = []


def verifier(condition: bool, marqueur: str, message: str) -> None:
    """Compte une verification, et enregistre le defaut si elle echoue."""
    global verifications
    verifications += 1
    if not condition:
        defauts.append(f"{marqueur} {message}")


class Structure(HTMLParser):
    """Empile les ouvrantes : compter les balises ne voit pas une imbrication fautive."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.pile: list[tuple[str, int]] = []
        self.erreurs: list[str] = []
        self.textes: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag not in VIDES:
            self.pile.append((tag, self.getpos()[0]))

    def handle_endtag(self, tag):
        if tag in VIDES:
            return
        if not self.pile:
            self.erreurs.append(f"ligne {self.getpos()[0]} : </{tag}> sans ouvrante")
            return
        ouvert, ligne = self.pile.pop()
        if ouvert != tag:
            self.erreurs.append(
                f"ligne {self.getpos()[0]} : </{tag}> ferme <{ouvert}> ouvert ligne {ligne}"
            )

    def handle_data(self, donnees):
        self.textes.append(donnees)


def pages_presentes(dossier: Path) -> list[str]:
    """Chemins relatifs de tous les `index.html` sous `docs/`."""
    return sorted(
        chemin.relative_to(dossier).as_posix()
        for chemin in dossier.rglob("index.html")
        if chemin.is_file()
    )


def controler(nom: str, racine: Path, relatif: str, coordonnees: tuple[str, ...]) -> None:
    chemin = racine / "docs" / relatif
    if not chemin.is_file():
        verifier(False, "[page-absente]", f"{nom} — {chemin} n'existe pas.")
        return

    brut = chemin.read_bytes()
    try:
        texte = brut.decode("utf-8")
    except UnicodeDecodeError as erreur:
        verifier(False, "[encodage]", f"{nom} — n'est pas de l'UTF-8 valide : {erreur}")
        return

    analyseur = Structure()
    analyseur.feed(texte)
    analyseur.close()

    problemes = analyseur.erreurs + [
        f"<{ouvert}> ouvert ligne {ligne} jamais ferme" for ouvert, ligne in analyseur.pile
    ]
    verifier(not problemes, "[structure]", f"{nom} — " + " ; ".join(problemes))

    # Le texte RENDU, pas le source : voir l'en-tete.
    visible = " ".join(analyseur.textes)

    restants = sorted(set(re.findall(r"\{\{[A-Z_]+\}\}", visible)))
    verifier(
        not restants,
        "[marqueur-non-rempli]",
        f"{nom} — marqueur affiche tel quel : {', '.join(restants)}",
    )

    absents = [attendu for attendu in coordonnees if attendu not in visible]
    verifier(
        not absents,
        "[coordonnee-absente]",
        f"{nom} — absent du texte affiche : {', '.join(absents)}",
    )

    # Un lien interne en absolu vise la racine du DOMAINE. On refuse la FORME,
    # et non les deux liens fautifs connus : une garde qui n'epargne que les cas
    # deja rencontres laisse revenir la meme faute ailleurs.
    # `(?!/)` epargne les adresses de protocole relatif (`//exemple.org`).
    absolus = re.findall(r'href="(/(?!/)[^"]*)"', texte)
    verifier(
        not absolus,
        "[lien-interne-absolu]",
        f"{nom} — viserait la racine du domaine, pas le site publie : {', '.join(absolus)}",
    )

    for cible in LIENS_ATTENDUS.get(nom, ()):
        verifier(
            f'href="{cible}"' in texte,
            "[lien-croise-absent]",
            f"{nom} — ne renvoie pas vers {cible}",
        )

    for phrase in PHRASES_ATTENDUES.get(nom, ()):
        verifier(
            phrase in visible,
            "[phrase-absente]",
            f"{nom} — « {phrase} » attendu et absent du texte affiche",
        )

    verifier("<title>" in texte, "[titre-absent]", f"{nom} — pas de <title>.")
    verifier('lang="fr"' in texte, "[langue-absente]", f"{nom} — langue non declaree.")

    print(f"  {nom:18} {len(brut):6} octets  {len(analyseur.textes)} fragments de texte")


def main(argv: list[str] | None = None) -> int:
    # La racine est parametrable pour que le banc vise une copie temporaire :
    # voir `Usage` dans l'en-tete.
    arguments = sys.argv[1:] if argv is None else argv
    racine = Path(arguments[0]).resolve() if arguments else RACINE_DEFAUT

    dossier = racine / "docs"
    if not dossier.is_dir():
        print(f"[dossier-absent] {dossier} n'existe pas.", file=sys.stderr)
        return 1

    presentes = pages_presentes(dossier)
    declarees = {relatif for relatif, _ in PAGES.values()}

    # Le sens que `controler` ne peut pas voir : une page AJOUTEE et non
    # declaree. Sans lui, un controle qui n'atteindrait qu'une page sur trois
    # passerait pour concluant. Le sens inverse — une page declaree qui manque —
    # est rendu par `controler`.
    for relatif in presentes:
        verifier(
            relatif in declarees,
            "[page-non-declaree]",
            f"{relatif} — present mais non declare dans PAGES.",
        )

    for nom, (relatif, coordonnees) in PAGES.items():
        controler(nom, racine, relatif, coordonnees)

    print(
        f"{len(PAGES)} page(s) attendue(s), {len(presentes)} presente(s), "
        f"{verifications} verification(s)."
    )
    if defauts:
        print(f"\n{len(defauts)} defaut(s) :\n")
        for defaut in defauts:
            print(f"  {defaut}")
        return 1
    print("Aucun defaut.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
