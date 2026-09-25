#!/usr/bin/env python3
"""Verifie que les pages publiees sont joignables — et que c'est le bon contenu.

Pourquoi ce fichier existe
--------------------------
Un `200` ne dit pas QUEL contenu est servi. Deux pieges, tous deux mesures le
25 septembre 2026 :

  * `raw.githubusercontent.com` est un CACHE DE DIFFUSION, pas le depot : apres
    un push, il servait le commit PRECEDENT, et une comparaison par cette voie
    concluait « DIFFERENT » a tort. L'instrument est le contenu servi par le
    site publie, pas la copie brute ;
  * une construction GitHub Pages repond `200` depuis la construction
    PRECEDENTE tant que la nouvelle n'est pas finie. Seule la comparaison du
    contenu le revele.

Ce controle confronte donc ce que le site SERT a ce que le depot CONTIENT, par
empreinte, et resout chaque lien interne. C'est le seul controle qui porte sur
la livraison elle-meme.

La liste des pages et celle des liens attendus sont IMPORTEES de
`verifier_pages.py` : recopiees, elles ne verifieraient qu'un accord avec
elles-memes.

Portee — et un controle de couverture doit dire ou il s'arrete
--------------------------------------------------------------
ATTRAPE : page injoignable (code != 200) ; contenu servi different du fichier
local ; lien interne qui ne mene nulle part ; marqueur non rempli dans le texte
servi ; page attendue absente du site.

N'ATTRAPE PAS : la fraicheur de la construction, sinon par la comparaison du
contenu ; une cible EXTERNE morte (quran.com, quranreflect.com), qui depend d'un
tiers ; une page visuellement fausse.

Usage
-----
    python tools/verifier_pages_en_ligne.py [base]

`base` par defaut : l'adresse de production du site.

Ce controle n'est PAS un portail d'integration continue : il depend du reseau et
d'une construction GitHub Pages qui met une a deux minutes. Il se lance APRES
une publication, pas a chaque push.

Code de sortie 0 si aucun defaut, 1 sinon.
"""

from __future__ import annotations

import hashlib
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urljoin

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verifier_pages import LIENS_ATTENDUS, PAGES, Structure  # noqa: E402

RACINE = Path(__file__).resolve().parent.parent
BASE_DEFAUT = "https://msoumaya2019.github.io/SoumayaQuran/"

verifications = 0
defauts: list[str] = []


def verifier(condition: bool, marqueur: str, message: str) -> None:
    global verifications
    verifications += 1
    if not condition:
        defauts.append(f"{marqueur} {message}")


def url_de(base: str, relatif: str) -> str:
    """`privacy/index.html` -> `<base>/privacy/` ; `index.html` -> `<base>`."""
    dossier = str(Path(relatif).parent)
    return base if dossier == "." else urljoin(base, dossier + "/")


def lire(url: str) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(url, timeout=30) as reponse:
            return reponse.status, reponse.read()
    except urllib.error.HTTPError as erreur:
        return erreur.code, b""
    except Exception as erreur:  # reseau, DNS, TLS
        return 0, str(erreur).encode("utf-8", "replace")


def code_seul(url: str) -> int:
    try:
        with urllib.request.urlopen(url, timeout=30) as reponse:
            return reponse.status
    except urllib.error.HTTPError as erreur:
        return erreur.code
    except Exception:
        return 0


def controler(nom: str, base: str, relatif: str) -> None:
    url = url_de(base, relatif)
    code, servi = lire(url)

    verifier(code == 200, "[page-injoignable]", f"{nom} — {url} rend {code}.")
    if code != 200:
        return

    local = (RACINE / "docs" / relatif).read_bytes()
    if servi != local:
        # Distinguer « contenu different » de « seule la mise en forme differe » :
        # la construction peut normaliser, elle ne doit pas changer le texte.
        texte_servi = re.sub(r"\s+", " ", servi.decode("utf-8", "replace"))
        texte_local = re.sub(r"\s+", " ", local.decode("utf-8", "replace"))
        indice = "texte identique, seule la mise en forme differe" if texte_servi == texte_local \
            else "LE TEXTE SERVI DIFFERE DU DEPOT"
        verifier(
            False,
            "[contenu-different]",
            f"{nom} — {url} : {len(servi)} octets servis contre {len(local)} en local "
            f"({indice}). Empreintes {hashlib.sha256(servi).hexdigest()[:12]} / "
            f"{hashlib.sha256(local).hexdigest()[:12]}.",
        )
    else:
        verifier(True, "", "")
        print(f"  {nom:18} {code}  {len(servi):6} octets  identique au depot")

    analyseur = Structure()
    analyseur.feed(servi.decode("utf-8", "replace"))
    analyseur.close()
    visible = " ".join(analyseur.textes)

    restants = sorted(set(re.findall(r"\{\{[A-Z_]+\}\}", visible)))
    verifier(
        not restants,
        "[marqueur-non-rempli]",
        f"{nom} — marqueur affiche tel quel sur le site : {', '.join(restants)}",
    )

    # Chaque lien interne est RESOLU, pas seulement cherche : c'est la faute
    # d'origine — le lien existait, visait la racine du domaine, et menait a 404.
    for cible in LIENS_ATTENDUS.get(nom, ()):
        absolu = urljoin(url, cible)
        verifier(
            code_seul(absolu) == 200,
            "[lien-mort]",
            f"{nom} — « {cible} » resolu en {absolu} ne rend pas 200.",
        )


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    base = arguments[0] if arguments else BASE_DEFAUT
    if not base.endswith("/"):
        base += "/"

    print(f"base : {base}")
    for nom, (relatif, _) in PAGES.items():
        controler(nom, base, relatif)

    print(f"\n{len(PAGES)} page(s), {verifications} verification(s).")
    if defauts:
        print(f"\n{len(defauts)} defaut(s) :\n")
        for defaut in defauts:
            print(f"  {defaut}")
        return 1
    print("Aucun defaut — le site sert le contenu du depot, et ses liens menent quelque part.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
