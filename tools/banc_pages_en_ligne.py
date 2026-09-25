#!/usr/bin/env python3
"""Banc de `verifier_pages_en_ligne.py` — un controle jamais falsifie ne vaut rien.

Le controle vert sur le vrai site ne prouve pas qu'il sait REFUSER. Ce banc sert
donc `docs/` depuis un serveur local, sur la boucle locale uniquement — aucun
acces reseau externe — et fabrique les deux refus qui comptent :

  1. **contenu different** — le site sert un texte qui n'est pas celui du depot.
     C'est le defaut le plus insidieux : les deux pages rendent 200, et seule la
     comparaison des octets le revele. Meme longueur ici, a dessein : un controle
     qui comparerait les TAILLES passerait ;
  2. **page injoignable** — la base ne repond pas.

Et le temoin : une copie locale intacte face a un site qui sert la meme chose
doit etre ACCEPTEE. Sans lui, un controle qui refuserait tout passerait.

Usage : python tools/banc_pages_en_ligne.py
"""

from __future__ import annotations

import functools
import http.server
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
DOCS = RACINE / "docs"
CONTROLE = "verifier_pages_en_ligne.py"


class Silencieux(http.server.SimpleHTTPRequestHandler):
    """Le serveur de test n'a pas a remplir la sortie du banc."""

    def log_message(self, *arguments):
        pass


def port_libre() -> int:
    with socket.socket() as prise:
        prise.bind(("127.0.0.1", 0))
        return prise.getsockname()[1]


def port_ferme() -> int:
    """Un port ou personne n'ecoute : la connexion sera refusee."""
    with socket.socket() as prise:
        prise.bind(("127.0.0.1", 0))
        return prise.getsockname()[1]


def servir(dossier: Path) -> tuple[http.server.ThreadingHTTPServer, str]:
    serveur = http.server.ThreadingHTTPServer(
        ("127.0.0.1", port_libre()),
        functools.partial(Silencieux, directory=str(dossier)),
    )
    threading.Thread(target=serveur.serve_forever, daemon=True).start()
    return serveur, f"http://127.0.0.1:{serveur.server_address[1]}/"


def lancer(controle: Path, base: str) -> tuple[int, str]:
    resultat = subprocess.run(
        [sys.executable, "-u", str(controle), base],
        capture_output=True,
        text=True,
    )
    return resultat.returncode, resultat.stdout + resultat.stderr


def main() -> int:
    echecs: list[str] = []
    reussites = 0

    with tempfile.TemporaryDirectory(prefix="en-ligne-") as brut:
        copie = Path(brut)
        shutil.copytree(RACINE / "tools", copie / "tools")
        shutil.copytree(DOCS, copie / "docs")
        controle = copie / "tools" / CONTROLE

        serveur, base = servir(DOCS)
        try:
            # Temoin : la copie locale est intacte, et le site sert la meme chose.
            code, sortie = lancer(controle, base)
            if code == 0:
                reussites += 1
                print("  ok    temoin : site et depot d'accord, accepte (code 0)")
            else:
                echecs.append(f"temoin : code {code}, attendu 0\n{sortie}")
                print("  KO    temoin : refuse alors qu'il devait passer")

            # Refus 1 : meme longueur, texte different.
            cible = copie / "docs" / "privacy" / "index.html"
            avant = cible.read_bytes()
            mute = avant.replace(b"TLS 1.2", b"TLS 1.3")
            if mute == avant:
                echecs.append("refus 1 : mutation non appliquee, ancre « TLS 1.2 » introuvable")
                print("  KO    contenu different : MUTATION NON APPLIQUEE")
            else:
                cible.write_bytes(mute)
                code, sortie = lancer(controle, base)
                if code == 1 and "[contenu-different]" in sortie:
                    reussites += 1
                    print("  ok    contenu different -> refuse, marqueur [contenu-different]")
                else:
                    echecs.append(
                        f"contenu different : code {code}, marqueur "
                        f"{'present' if '[contenu-different]' in sortie else 'ABSENT'}\n{sortie}"
                    )
                    print(f"  KO    contenu different : code {code}")
                cible.write_bytes(avant)

            # Refus 2 : plus personne n'ecoute.
            code, sortie = lancer(controle, f"http://127.0.0.1:{port_ferme()}/")
            if code == 1 and "[page-injoignable]" in sortie:
                reussites += 1
                print("  ok    page injoignable -> refuse, marqueur [page-injoignable]")
            else:
                echecs.append(
                    f"page injoignable : code {code}, marqueur "
                    f"{'present' if '[page-injoignable]' in sortie else 'ABSENT'}\n{sortie}"
                )
                print(f"  KO    page injoignable : code {code}")
        finally:
            serveur.shutdown()

    print(f"\n{reussites} cas vert(s), {len(echecs)} echec(s).")
    if echecs:
        print("\nEchecs :")
        for echec in echecs:
            print(f"  - {echec}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
