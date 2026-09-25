#!/usr/bin/env python3
"""Confronte les deux documents publies a la checklist officielle de la fondation.

Pourquoi ce fichier existe
--------------------------
`verifier_pages.py` etablit qu'une page tient debout ; il ne dit rien de son
FOND. Une page parfaitement formee, aux liens justes et aux coordonnees
lisibles, peut avoir oublie la moitie de ce que la Developer Privacy Policy
Packet exige — et personne ne s'en apercevrait, puisque le document est lu par
un tiers et jamais par un test.

Une exigence non satisfaite parce qu'elle ne s'applique pas n'est pas un defaut —
a condition que le document DISE POURQUOI. Ce controle refuse donc une exigence
sans objet dont la justification est absente : sans cela, un relecteur ne peut
pas distinguer « sans objet » de « oublie ».

Les textes sont lus RENDUS (fragments de texte), pas dans la source : une phrase
presente seulement dans un commentaire HTML ne s'afficherait pas.

Portee — et un controle de couverture doit dire ou il s'arrete
--------------------------------------------------------------
ATTRAPE : exigence de la checklist dont aucun attendu n'apparait dans le texte
affiche ; exigence declaree sans objet dont la raison n'est pas ecrite ; phrase
attendue absente ; document absent.

N'ATTRAPE PAS : une exigence que la checklist exige et que ces tables ne
listent pas — la couverture est celle des tables, et non celle du paquet ; une
formulation juridiquement faible mais presente ; la joignabilite en ligne.

Usage
-----
    python tools/verifier_conformite.py [racine]

`racine` vise une COPIE temporaire, pour que le banc falsifie ce controle sans
jamais muter les vrais fichiers. Defaut : la racine du depot.

Code de sortie 0 si aucun defaut, 1 sinon. Chaque defaut porte un marqueur ASCII
entre crochets, pour qu'un banc puisse s'y accrocher sans dependre de l'encodage.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path

RACINE_DEFAUT = Path(__file__).resolve().parent.parent

# Liste FERMEE des documents confrontes a la checklist.
DOCUMENTS = ("privacy/index.html", "terms/index.html")


class Texte(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.fragments: list[str] = []

    def handle_data(self, donnees: str) -> None:
        self.fragments.append(donnees)


def rendre(chemin: Path) -> str:
    analyseur = Texte()
    analyseur.feed(chemin.read_text(encoding="utf-8"))
    analyseur.close()
    # Les retours a la ligne du source coupent les phrases : « ... l'obligeant a
    # proteger les donnees ... ». Sans normalisation, une phrase presente est
    # declaree absente — un faux defaut, qui ferait « corriger » une page juste.
    # Mesure faite : deux exigences signalees a tort pour cette seule raison.
    return re.sub(r"\s+", " ", " ".join(analyseur.fragments))


@dataclass
class Exigence:
    reference: str
    intitule: str
    attendus: tuple[str, ...] = ()
    sans_objet: str | None = None
    ecart: str | None = None


# Developer Privacy Policy Packet — sections 1 a 9.
CONFIDENTIALITE = (
    Exigence("§1 A", "nom de l'application et usage des API QF",
             ("Soumaya", "API de la Quran Foundation")),
    Exigence("§1 B", "situation dans l'ecosysteme", ("Quran.com", "QuranReflect")),
    Exigence("§1 C", "date de derniere mise a jour", ("Dernière mise à jour",)),
    Exigence("§2 A", "donnees collectees, et contenu obtenu sans donnee personnelle",
             ("ne collecte aucune donnée personnelle", "sans collecter de données personnelles")),
    Exigence("§2 B", "base legale de chaque traitement",
             ("aucune base légale de traitement n'est requise",)),
    Exigence("§2 C", "usages interdits",
             ("profils publicitaires", "vendue, exploitée ou réaffectée", "entraîner des modèles")),
    Exigence("§2 D", "consentement explicite pour les donnees religieuses",
             sans_objet="Aucune donnée relative aux croyances"),
    Exigence("§3 A", "sous-traitants et liens vers leurs politiques",
             ("sous-traitant", "quran.com/privacy", "quranreflect.com/privacy")),
    Exigence("§3 B", "engagement contractuel envers les tiers",
             ("lié par un contrat l'obligeant à protéger les données",)),
    Exigence("§4 A", "TLS, chiffrement au repos, controle d'acces, rotation du secret",
             ("TLS 1.2", "rotation du secret", "espace privé", "chiffr")),
    Exigence("§4 B", "delai de reponse a un incident",
             ("dans les 24 heures", "developers@quran.com")),
    Exigence("§4 C", "reference a la regle de securite nommee", ("Security Rule 6.9",)),
    Exigence("§5 A", "revocation d'un acces OAuth",
             sans_objet="aucun jeton d'accès vous concernant à révoquer"),
    Exigence("§5 B", "suppression des donnees",
             sans_objet="La désinstallation de l'application supprime"),
    Exigence("§5 C", "droit d'acces et de rectification", ("droits d'accès", "rectification")),
    Exigence("§6 A", "duree de conservation",
             sans_objet="Aucune donnée personnelle n'étant conservée"),
    Exigence("§6 B", "suppression sous 30 jours, sauvegardes sous 90 jours",
             sans_objet="il n'y a pas de durée de conservation à définir"),
    Exigence("§6 C", "effet de la suppression du compte QF",
             sans_objet="aucune session utilisateur auprès de la Quran Foundation"),
    Exigence("§7 A", "application non destinee aux moins de 13 ans",
             ecart="§7 A — la déclaration d'exclusion des moins de 13 ans est ÉCARTÉE : "
                   "l'application ne recueille aucune donnée, de personne, et l'exclure "
                   "d'un usage familial serait faux."),
    Exigence("§8 A-C", "transferts internationaux", ("Transferts internationaux", "hors de votre pays")),
    Exigence("§9 A", "information des modifications", ("modification substantielle sera signalée",)),
    Exigence("§9 B", "contact et delai de reponse",
             ("axox93@hotmail.fr", "Avenue Gallieni", "30 jours")),
)

# Obligations des Developer Terms qui redescendent dans les conditions d'utilisation.
CONDITIONS = (
    Exigence("Terms §3.2", "documents publiquement joignables",
             ("conditions", "confidentialité")),
    Exigence("Terms §2.2", "caractere independant, non officiel",
             ("produit indépendant", "pas une application officielle")),
    Exigence("Terms §2.2", "texte coranique jamais modifie",
             ("n'est en aucune façon modifié",)),
    Exigence("Terms §2.2", "ni vente, ni sous-licence, ni redistribution",
             ("ni vendu, ni sous-licencié, ni redistribué",)),
    Exigence("Terms §3.1", "aspiration et quotas",
             ("extraire, d'aspirer ou d'indexer", "contourner les limitations techniques")),
    Exigence("Terms §3.1", "profils, biometrie, modeles",
             ("profils publicitaires", "biométriques", "modèles d'apprentissage")),
    Exigence("Terms §3.1", "usages denigrants ou extremistes",
             ("dénigrant l'islam", "extrémiste")),
    Exigence("Terms §8", "garanties declinees, fondation non responsable",
             ("en l'état", "n'est pas responsable de cette application")),
    Exigence("Terms §5-6", "interruption possible du service", ("ne garantit pas", "suspendu")),
    Exigence("Terms §10", "droit applicable", ("droit français",)),
    Exigence("Terms §9", "modification des conditions", ("modification substantielle sera signalée",)),
    Exigence("Terms §10", "contact",
             ("axox93@hotmail.fr", "Avenue Gallieni")),
)

verifications = 0
defauts: list[str] = []


def verifier(condition: bool, marqueur: str, message: str) -> None:
    """Compte une verification, et enregistre le defaut si elle echoue."""
    global verifications
    verifications += 1
    if not condition:
        defauts.append(f"{marqueur} {message}")


def controler(page: str, racine: Path, relatif: str, exigences: tuple[Exigence, ...]) -> None:
    chemin = racine / "docs" / relatif
    if not chemin.is_file():
        verifier(False, "[document-absent]", f"{page} — {chemin} n'existe pas.")
        return

    texte = rendre(chemin)
    print(f"\n--- {page} ---")

    for e in exigences:
        if e.ecart is not None:
            # Un ecart assume n'est pas un oubli : il est compte, et affiche.
            verifier(
                bool(e.ecart.strip()),
                "[ecart-non-justifie]",
                f"{page} {e.reference} : ecart declare sans justification ecrite.",
            )
            print(f"  {e.reference:11} ECART    {e.intitule}")
            print(f"              {e.ecart}")
            continue

        if e.sans_objet is not None:
            justifie = e.sans_objet in texte
            verifier(
                justifie,
                "[sans-objet-non-justifie]",
                f"{page} {e.reference} : exigence sans objet mais la raison n'est pas ecrite "
                f"(attendu « {e.sans_objet} »)",
            )
            if justifie:
                print(f"  {e.reference:11} sans objet, et la raison est ecrite — {e.intitule}")
            else:
                print(f"  {e.reference:11} ABSENT   {e.intitule}")
            continue

        manquants = [a for a in e.attendus if a not in texte]
        verifier(
            not manquants,
            "[exigence-absente]",
            f"{page} {e.reference} : {e.intitule} — manque {', '.join(manquants)}",
        )
        if manquants:
            print(f"  {e.reference:11} ABSENT   {e.intitule}  -> {', '.join(manquants)}")
        else:
            print(f"  {e.reference:11} present  {e.intitule}")


def main(argv: list[str] | None = None) -> int:
    # La racine est parametrable pour que le banc vise une copie temporaire.
    arguments = sys.argv[1:] if argv is None else argv
    racine = Path(arguments[0]).resolve() if arguments else RACINE_DEFAUT

    controler("politique de confidentialite", racine, DOCUMENTS[0], CONFIDENTIALITE)
    controler("conditions d'utilisation", racine, DOCUMENTS[1], CONDITIONS)

    print()
    print(f"{len(CONFIDENTIALITE) + len(CONDITIONS)} exigence(s), {verifications} verification(s).")
    if defauts:
        print(f"\n{len(defauts)} defaut(s) :\n")
        for defaut in defauts:
            print(f"  {defaut}")
        return 1
    print("Aucun defaut — chaque exigence est satisfaite, ou declaree sans objet avec sa raison.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
