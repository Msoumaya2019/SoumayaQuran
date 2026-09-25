#!/usr/bin/env python3
"""Rend les `--dart-define` a passer a `flutter build`, en n'en passant que de renseignes.

Pourquoi ce fichier existe
--------------------------
Un `--dart-define` defini mais VIDE l'emporte sur le `defaultValue` du code.
Mesure faite :

    String.fromEnvironment('SOUMAYA_TEST', defaultValue: 'defaut')
    dart run -DSOUMAYA_TEST=   ->   ""

C'est-a-dire que la valeur par defaut n'est pas seulement ignoree : elle est
remplacee par une chaine vide, et le code qui teste `isEmpty` pour retomber sur
son defaut ne voit plus rien a quoi se raccrocher.

Consequence concrete sur ce depot : la CI passait

    --dart-define="SOUMAYA_QCF_FONT_BASE_URL=${{ vars.SOUMAYA_QCF_FONT_BASE_URL }}"

et comme cette variable de depot n'est pas renseignee, l'application livree
embarquait une base de polices VIDE — donc le repli par defaut, ajoute au code
precisement pour ce cas, ne servait a rien. Le defaut etait invisible : la
compilation reussissait, et le seul temoin vivant a l'execution.

Deuxieme raison : la meme boucle vivait en double, une fois par job. C'est la
copie qui a garde le defaut quand l'original a ete corrige. Une seule source.

Contrat
-------
Sortie standard : la suite d'arguments, separes par des espaces, ou rien.
Sortie d'erreur  : des annotations GitHub (`::warning::`, `::error::`), que le
                   journal de la CI affiche comme telles et que la machine
                   locale affiche comme du texte.
Code de sortie   : 0, ou 1 si une valeur ne peut pas etre passee telle quelle.

Usage
-----
    python3 tools/defines_dart.py

Le script lit l'environnement, jamais un fichier : c'est ce que fait la CI, et
c'est ce qui le rend eprouvable en local sans rien ecrire.
"""

from __future__ import annotations

import os
import sys

# Liste FERMEE. Une variable ajoutee ici devient transmise ; une variable
# oubliee ici ne l'est pas, en silence. C'est le seul endroit a modifier.
NOMS = (
    "SOUMAYA_PROXY_BASE_URL",
    "SOUMAYA_QF_CLIENT_ID",
    "SOUMAYA_QCF_FONT_BASE_URL",
)

# Une valeur qui contient un blanc casserait la ligne de commande : le shell la
# decouperait en plusieurs arguments, et `flutter build` recevrait une option
# tronquee sans le dire. On refuse plutot que de produire une commande fausse.
BLANCS = (" ", "\t", "\n", "\r")

MARQUEUR_VALEUR_INVALIDE = "[valeur-invalide]"


class ValeurInvalide(Exception):
    """La valeur ne peut pas etre passee telle quelle sur la ligne de commande."""

    def __init__(self, nom: str) -> None:
        super().__init__(nom)
        self.nom = nom


def arguments(environnement: dict[str, str]) -> tuple[str, list[str]]:
    """Rend (arguments, noms manquants).

    Separe du `main` pour que le banc puisse l'appeler directement, sans
    processus ni environnement a fabriquer.
    """
    morceaux: list[str] = []
    manquantes: list[str] = []

    for nom in NOMS:
        valeur = environnement.get(nom, "")
        if valeur == "":
            # Renseignee a vide et absente sont le meme cas, et doivent le
            # rester : c'est le comportement de la CI, ou une variable de depot
            # non definie arrive en chaine vide.
            manquantes.append(nom)
            continue
        if any(blanc in valeur for blanc in BLANCS):
            raise ValeurInvalide(nom)
        morceaux.append(f"--dart-define={nom}={valeur}")

    return " ".join(morceaux), manquantes


def resume_manquantes(manquantes: list[str]) -> str:
    """Le bloc a ajouter au resume du job, ou une chaine vide."""
    if not manquantes:
        return ""
    vides = ", ".join(f"`{nom}`" for nom in manquantes)
    return (
        "### Variables de depot absentes\n"
        "\n"
        f"Vides : {vides}.\n"
        "\n"
        "Leurs `--dart-define` ne sont pas passes : les valeurs par defaut du\n"
        "code s'appliquent. Les passer vides serait pire — un `--dart-define`\n"
        "vide l'emporte sur le `defaultValue`.\n"
        "\n"
        "La compilation aboutit quand meme — c'est son objet ici — mais\n"
        "l'application ne pourra joindre ni le proxy, ni l'API. Les polices,\n"
        "elles, viennent du CDN public de la fondation et se chargent sans\n"
        "configuration.\n"
        "\n"
    )


def main() -> int:
    try:
        args, manquantes = arguments(dict(os.environ))
    except ValeurInvalide as erreur:
        print(
            f"::error::La variable {erreur.nom} contient un blanc "
            f"{MARQUEUR_VALEUR_INVALIDE} : elle serait decoupee en plusieurs "
            "arguments par le shell.",
            file=sys.stderr,
        )
        return 1

    for nom in manquantes:
        print(
            f"::warning::La variable de depot {nom} est vide : "
            "son --dart-define n'est pas passe.",
            file=sys.stderr,
        )

    bloc = resume_manquantes(manquantes)
    chemin_resume = os.environ.get("GITHUB_STEP_SUMMARY", "")
    if bloc and chemin_resume:
        with open(chemin_resume, "a", encoding="utf-8") as resume:
            resume.write(bloc)

    print(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
