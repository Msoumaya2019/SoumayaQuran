#!/usr/bin/env python3
"""Banc de `verifier_pages.py` et `verifier_conformite.py` — un controle jamais falsifie ne vaut rien.

Un controle vert sur des pages justes ne prouve pas qu'il sait REFUSER. Ce banc
travaille donc sur une COPIE temporaire de `docs/`, hors du depot, y introduit un
defaut reel, et exige du controle nomme qu'il le refuse — **par le marqueur
attendu**, et non seulement qu'il rende un code non nul.

Pourquoi une copie, et non une sauvegarde suivie d'une restauration
------------------------------------------------------------------
Un banc qui ecrit dans les vrais fichiers puis les restaure abime ce qu'il
touche : sous Windows, `write_text` traduit `\\n` en `\\r\\n`, et la restauration
n'est pas fidele a l'octet. Le depot a deja paye ce prix ailleurs — le controle
des flux le dit dans son propre en-tete. La copie supprime le probleme au lieu
de le gerer.

Ce que ce banc exige, cas par cas
---------------------------------
  1. **balise fermante retiree**            -> structure, `[structure]`
  2. **coordonnees -> marqueur non rempli** -> structure, `[marqueur-non-rempli]`
  3. **lien croise retire**                 -> structure, `[lien-croise-absent]`
  4. **lien interne remis en absolu**       -> structure, `[lien-interne-absolu]`
  5. **page ajoutee non declaree**          -> structure, `[page-non-declaree]`
  6. **regle de securite nommee retiree**   -> conformite, `[exigence-absente]`
  7. **justification d'un « sans objet » retiree** -> conformite, `[sans-objet-non-justifie]`

Et le temoin : la copie intacte doit etre ACCEPTEE par les deux controles. Sans
lui, un controle qui refuserait tout passerait pour concluant.

Et une mesure que le banc doit faire lui-meme : **au moins un cas doit faire
rougir `conformite` SEUL**. Sans cette ligne, un audit qui ne saurait dire que
« oui », ou qui ne ferait que repeter le controle de structure, passerait ce
banc — c'est precisement ce qui s'etait produit avant que le cas 7 n'existe.

Usage : python tools/banc_pages.py
"""

from __future__ import annotations

import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
DOCS = RACINE / "docs"
CONTROLES = {
    "structure": RACINE / "tools" / "verifier_pages.py",
    "conformite": RACINE / "tools" / "verifier_conformite.py",
}


class AncreIntrouvable(Exception):
    """La mutation n'a pas pu etre appliquee : le texte vise n'existe plus."""


def remplacer(chemin: Path, cible: str, remplacement: str) -> None:
    """Remplace la premiere occurrence, en OCTETS.

    En octets, et non par `read_text`/`write_text` : voir l'en-tete.

    Lever plutot que ne rien faire : une mutation non appliquee laisserait le
    controle vert, et le banc conclurait « non detecte » — en accusant le
    controle d'un defaut qui vient de l'ancre. Les trois causes se ressemblent
    ensuite : ancre introuvable, controle aveugle, mutation mal visee.
    """
    donnees = chemin.read_bytes()
    ancien = cible.encode("utf-8")
    if ancien not in donnees:
        raise AncreIntrouvable(f"{chemin.name} : ancre absente — {cible[:70]!r}")
    chemin.write_bytes(donnees.replace(ancien, remplacement.encode("utf-8"), 1))


def balise_fermante(docs: Path) -> None:
    remplacer(
        docs / "privacy" / "index.html",
        "</ul>\n\n  <h2>7. Conservation",
        "\n\n  <h2>7. Conservation",
    )


def marqueur_non_rempli(docs: Path) -> None:
    remplacer(
        docs / "privacy" / "index.html",
        "Responsable du traitement : Mohamed C",
        "Responsable du traitement : {{RESPONSABLE}}",
    )


def lien_croise_retire(docs: Path) -> None:
    remplacer(
        docs / "privacy" / "index.html",
        '<a href="../terms/">conditions d\'utilisation</a>',
        "conditions d'utilisation",
    )


def lien_interne_absolu(docs: Path) -> None:
    """La faute d'origine : `href="/terms/"` vise la racine du domaine."""
    remplacer(docs / "privacy" / "index.html", '<a href="../terms/">', '<a href="/terms/">')


def page_non_declaree(docs: Path) -> None:
    """Ajoute une page que `PAGES` ne declare pas.

    C'est le sens que le controle ne peut pas voir autrement : sans cette regle,
    un controle qui n'atteindrait qu'une page sur trois passerait pour concluant.
    """
    (docs / "mentions").mkdir(parents=True, exist_ok=True)
    (docs / "mentions" / "index.html").write_bytes(
        b'<!DOCTYPE html>\n<html lang="fr"><head><meta charset="utf-8">'
        b"<title>Mentions</title></head><body><p>Ajoutee par le banc.</p></body></html>\n"
    )


def regle_securite_retiree(docs: Path) -> None:
    remplacer(docs / "privacy" / "index.html", "Security Rule 6.9", "regle interne non nommee")


def justification_sans_objet_retiree(docs: Path) -> None:
    remplacer(
        docs / "privacy" / "index.html",
        "Aucune donnée relative aux croyances",
        "Sans objet",
    )


# (nom, mutation, controle qui DOIT refuser, marqueur attendu dans sa sortie)
CAS = (
    ("balise fermante retiree", balise_fermante, "structure", "[structure]"),
    ("coordonnees -> marqueur non rempli", marqueur_non_rempli, "structure", "[marqueur-non-rempli]"),
    ("lien croise retire", lien_croise_retire, "structure", "[lien-croise-absent]"),
    ("lien interne remis en absolu", lien_interne_absolu, "structure", "[lien-interne-absolu]"),
    ("page ajoutee non declaree", page_non_declaree, "structure", "[page-non-declaree]"),
    ("regle de securite nommee retiree", regle_securite_retiree, "conformite", "[exigence-absente]"),
    (
        "justification d'un « sans objet » retiree",
        justification_sans_objet_retiree,
        "conformite",
        "[sans-objet-non-justifie]",
    ),
)


def empreinte_arbre(dossier: Path) -> dict[str, str]:
    """Empreinte de chaque fichier : sert a prouver que le banc n'ecrit pas dans le depot."""
    return {
        chemin.relative_to(dossier).as_posix(): hashlib.sha256(chemin.read_bytes()).hexdigest()
        for chemin in sorted(dossier.rglob("*"))
        if chemin.is_file()
    }


def lancer(racine: Path) -> tuple[set[str], dict[str, str]]:
    """Controles qui echouent, et leur sortie complete."""
    en_echec: set[str] = set()
    sorties: dict[str, str] = {}
    for nom, programme in CONTROLES.items():
        resultat = subprocess.run(
            [sys.executable, "-u", str(programme), str(racine)],
            capture_output=True,
            text=True,
        )
        sorties[nom] = resultat.stdout + resultat.stderr
        if resultat.returncode != 0:
            en_echec.add(nom)
    return en_echec, sorties


def copie_de_docs(dossier: str) -> Path:
    """Copie `docs/` sous `<dossier>/docs`, la ou les controles la cherchent."""
    shutil.copytree(DOCS, Path(dossier) / "docs")
    return Path(dossier)


def main() -> int:
    echecs: list[str] = []
    reussites = 0
    conformite_seule = False

    avant = empreinte_arbre(DOCS)

    with tempfile.TemporaryDirectory(prefix="pages-temoin-") as brut:
        racine = copie_de_docs(brut)
        en_echec, sorties = lancer(racine)
        if not en_echec:
            reussites += 1
            print("  ok    temoin : copie intacte acceptee par les deux controles")
        else:
            echecs.append(f"temoin : refuse par {sorted(en_echec)} alors qu'il devait passer")
            print(f"  KO    temoin : refuse par {sorted(en_echec)}")
            for nom in sorted(en_echec):
                print(f"        --- {nom} ---\n{sorties[nom]}")

    for nom, mutation, controle_attendu, marqueur in CAS:
        with tempfile.TemporaryDirectory(prefix="pages-") as brut:
            racine = copie_de_docs(brut)
            try:
                mutation(racine / "docs")
            except AncreIntrouvable as erreur:
                echecs.append(f"{nom} : ancre introuvable, mutation NON APPLIQUEE — {erreur}")
                print(f"  KO    {nom} : ANCRE INTROUVABLE (mutation non appliquee)")
                continue

            en_echec, sorties = lancer(racine)

            if controle_attendu not in en_echec:
                echecs.append(
                    f"{nom} : `{controle_attendu}` reste VERT alors que la source est mutee "
                    f"(rouges : {sorted(en_echec) or 'aucun'})"
                )
                print(f"  KO    {nom} : `{controle_attendu}` reste vert")
                continue

            if marqueur not in sorties[controle_attendu]:
                echecs.append(
                    f"{nom} : `{controle_attendu}` refuse, mais sans {marqueur} — "
                    f"il ne refuse pas pour la raison attendue"
                )
                print(f"  KO    {nom} : refuse sans {marqueur}")
                continue

            reussites += 1
            autres = sorted(en_echec - {controle_attendu})
            if controle_attendu == "conformite" and not autres:
                conformite_seule = True
            print(
                f"  ok    {nom} -> `{controle_attendu}` refuse, marqueur {marqueur}"
                + (f" (aussi : {', '.join(autres)})" if autres else "")
            )

    apres = empreinte_arbre(DOCS)
    if apres != avant:
        modifies = sorted(
            cle for cle in set(avant) | set(apres) if avant.get(cle) != apres.get(cle)
        )
        echecs.append(f"LE BANC A MODIFIE LE DEPOT : {', '.join(modifies)}")
        print(f"  KO    le depot a ete modifie par le banc : {', '.join(modifies)}")
    else:
        reussites += 1
        print(f"  ok    le depot est intact ({len(avant)} fichier(s) sous docs/, empreintes identiques)")

    if not conformite_seule:
        echecs.append(
            "aucun cas ne fait rougir `conformite` SEUL : son pouvoir de refus n'est pas etabli"
        )
        print("  KO    `conformite` n'a jamais rougi seul")

    print(f"\n{reussites} cas vert(s), {len(echecs)} echec(s).")
    if echecs:
        print("\nEchecs :")
        for echec in echecs:
            print(f"  - {echec}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
