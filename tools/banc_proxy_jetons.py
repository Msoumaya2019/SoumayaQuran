#!/usr/bin/env python3
"""Banc du proxy de jetons — un banc qui n'a jamais refuse ne vaut rien.

`platform/proxy/qf-token-proxy.mjs` est le SEUL detenteur du `client_secret` :
c'est la piece sur laquelle repose tout le modele de securite du projet. Il
n'avait pourtant aucune suite de tests. Ce banc en tient lieu : il lance le vrai
proxy, avec un **faux serveur Quran Foundation** sur la boucle locale, et
fabrique les conditions qui doivent le faire refuser.

Ce qu'il eprouve, et pourquoi chaque cas compte
-----------------------------------------------
  1. **temoin** — `/health` repond, et le proxy demarre vraiment ;
  2. **jeton delivre** — `/qf/token` rend le jeton du faux amont ;
  3. **le secret ne fuit pas** — il n'apparait dans AUCUNE reponse. C'est
     l'assertion qui justifie l'existence du proxy : un secret extractible dans
     un APK donnerait a n'importe qui le controle du quota ;
  4. **authentification amont** — le proxy presente bien un `Basic` construit
     sur `client_id` et `client_secret` ; sans cela l'amont refuserait en
     production sans qu'on le sache ici ;
  5. **jeton mis en cache** — deux appels ne produisent qu'UN echange amont.
     Sans cache, chaque appel d'application consommerait du quota ;
  6. **chemin inconnu -> 404**, **methode non GET -> 405** ;
  7. **limite de debit -> 429** au-dela du seuil configure ;
  8. **amont en echec -> 502**, et le corps d'erreur amont — qui peut porter des
     identifiants — n'est PAS recopie dans la reponse.

Le cas 8 est le seul que la relecture ne peut pas etablir : il faut faire
echouer l'amont pour voir ce qui ressort.

Usage : python tools/banc_proxy_jetons.py
"""

from __future__ import annotations

import base64
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
PROXY = RACINE / "platform" / "proxy" / "qf-token-proxy.mjs"

IDENTIFIANT_FACTICE = "client-de-test"
SECRET_FACTICE = "secret-de-test-qui-ne-doit-jamais-fuiter"
JETON_FACTICE = "jeton-de-test-1234567890"


class FauxQuranFoundation(http.server.BaseHTTPRequestHandler):
    """Faux amont : rend un jeton, ou echoue en recopiant le secret dans son corps."""

    echanges = 0
    en_echec = False
    derniere_autorisation: str | None = None

    def do_POST(self):  # noqa: N802 - nom impose par la bibliotheque
        longueur = int(self.headers.get("content-length") or 0)
        self.rfile.read(longueur)
        FauxQuranFoundation.echanges += 1
        FauxQuranFoundation.derniere_autorisation = self.headers.get("authorization")

        if FauxQuranFoundation.en_echec:
            # Le corps porte le secret, comme le ferait un vrai message
            # d'erreur d'identifiants : c'est ce qui rend le cas 8 mesurable.
            corps = json.dumps(
                {"error": "invalid_client", "detail": SECRET_FACTICE}
            ).encode("utf-8")
            code = 500
        else:
            corps = json.dumps(
                {"access_token": JETON_FACTICE, "token_type": "Bearer", "expires_in": 3600}
            ).encode("utf-8")
            code = 200

        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def log_message(self, *arguments):
        pass


def port_libre() -> int:
    with socket.socket() as prise:
        prise.bind(("127.0.0.1", 0))
        return prise.getsockname()[1]


def servir_faux_amont() -> str:
    serveur = http.server.ThreadingHTTPServer(("127.0.0.1", port_libre()), FauxQuranFoundation)
    threading.Thread(target=serveur.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{serveur.server_address[1]}"


def attendre(base: str, processus: subprocess.Popen, delai: float = 20.0) -> None:
    limite = time.time() + delai
    while time.time() < limite:
        if processus.poll() is not None:
            raise RuntimeError(f"le proxy s'est arrete tout seul (code {processus.returncode})")
        try:
            with urllib.request.urlopen(base + "/health", timeout=1) as reponse:
                if reponse.status == 200:
                    return
        except Exception:
            time.sleep(0.15)
    raise RuntimeError("le proxy n'a pas repondu dans le delai")


def demarrer_proxy(amont: str, limite: int) -> tuple[subprocess.Popen, str]:
    port = port_libre()
    environnement = dict(os.environ)
    environnement.update(
        {
            "QF_CLIENT_ID": IDENTIFIANT_FACTICE,
            "QF_CLIENT_SECRET": SECRET_FACTICE,
            "QF_AUTH_BASE_URL": amont,
            "PORT": str(port),
            "RATE_LIMIT_PER_HOUR": str(limite),
        }
    )
    processus = subprocess.Popen(
        ["node", str(PROXY)],
        env=environnement,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    base = f"http://127.0.0.1:{port}"
    attendre(base, processus)
    return processus, base


def appeler(url: str, methode: str = "GET") -> tuple[int, str]:
    requete = urllib.request.Request(url, method=methode)
    try:
        with urllib.request.urlopen(requete, timeout=10) as reponse:
            return reponse.status, reponse.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as erreur:
        return erreur.code, erreur.read().decode("utf-8", "replace")
    except Exception as erreur:
        return 0, str(erreur)


def main() -> int:
    if shutil.which("node") is None:
        print("[node-absent] Node est requis pour lancer le proxy.", file=sys.stderr)
        return 1

    echecs: list[str] = []
    reussites = 0
    corps_vus: list[str] = []

    def exiger(condition: bool, nom: str, detail=None) -> None:
        """`detail` est un CALLABLE, et non une chaine.

        Une chaine serait construite avant l'appel, donc meme quand la condition
        est vraie : un detail qui indexe une liste vide fait alors tomber le banc
        sur un cas qui PASSE. Mesure faite — neuf cas verts, puis un
        `IndexError` sur le message de succes de la dixieme assertion.
        """
        nonlocal reussites
        if condition:
            reussites += 1
            print(f"  ok    {nom}")
        else:
            message = detail() if detail else ""
            echecs.append(f"{nom} — {message}")
            print(f"  KO    {nom} : {message}")

    amont = servir_faux_amont()

    # --- Groupe fonctionnel : limite haute, pour ne pas la declencher ---------
    FauxQuranFoundation.echanges = 0
    FauxQuranFoundation.en_echec = False
    processus, base = demarrer_proxy(amont, limite=1000)
    try:
        code, corps = appeler(base + "/health")
        corps_vus.append(corps)
        exiger(code == 200 and json.loads(corps).get("ok") is True,
               "temoin : /health repond 200", lambda: f"code {code}, corps {corps[:80]}")

        code, corps = appeler(base + "/qf/token")
        corps_vus.append(corps)
        jeton = json.loads(corps).get("access_token") if code == 200 else None
        exiger(code == 200 and jeton == JETON_FACTICE,
               "jeton delivre", lambda: f"code {code}, jeton {jeton!r}")

        attendu = "Basic " + base64.b64encode(
            f"{IDENTIFIANT_FACTICE}:{SECRET_FACTICE}".encode()
        ).decode()
        exiger(FauxQuranFoundation.derniere_autorisation == attendu,
               "authentification amont en Basic sur client_id + client_secret",
               lambda: f"recu {FauxQuranFoundation.derniere_autorisation!r}")

        echanges_apres_premier = FauxQuranFoundation.echanges
        code, corps = appeler(base + "/qf/token")
        corps_vus.append(corps)
        exiger(code == 200 and FauxQuranFoundation.echanges == echanges_apres_premier,
               "jeton mis en cache : un seul echange amont",
               lambda: f"echanges {echanges_apres_premier} -> {FauxQuranFoundation.echanges}")

        code, corps = appeler(base + "/inconnu")
        corps_vus.append(corps)
        exiger(code == 404, "chemin inconnu refuse en 404", lambda: f"code {code}")

        code, corps = appeler(base + "/qf/token", methode="POST")
        corps_vus.append(corps)
        exiger(code == 405, "methode non GET refusee en 405", lambda: f"code {code}")
    finally:
        processus.terminate()
        processus.wait(timeout=10)

    # --- Groupe limite de debit ----------------------------------------------
    FauxQuranFoundation.echanges = 0
    processus, base = demarrer_proxy(amont, limite=2)
    try:
        codes = [appeler(base + "/qf/token")[0] for _ in range(3)]
        corps_vus.append(str(codes))
        exiger(codes[:2] == [200, 200] and codes[2] == 429,
               "limite de debit : 429 au-dela du seuil",
               lambda: f"codes {codes}")
    finally:
        processus.terminate()
        processus.wait(timeout=10)

    # --- Groupe amont en echec ----------------------------------------------
    FauxQuranFoundation.echanges = 0
    FauxQuranFoundation.en_echec = True
    processus, base = demarrer_proxy(amont, limite=1000)
    try:
        code, corps = appeler(base + "/qf/token")
        corps_vus.append(corps)
        exiger(code == 502, "amont en echec -> 502", lambda: f"code {code}")
        exiger("Échange de jeton impossible" in corps,
               "le message reste generique", lambda: f"corps {corps[:100]}")
    finally:
        processus.terminate()
        processus.wait(timeout=10)
    FauxQuranFoundation.en_echec = False

    # --- L'assertion qui justifie le proxy -----------------------------------
    fuites = [c for c in corps_vus if SECRET_FACTICE in c]
    exiger(not fuites,
           "le secret n'apparait dans AUCUNE reponse",
           lambda: f"{len(fuites)} reponse(s) le contiennent, dont {fuites[0][:100]!r}")

    print(f"\n{reussites} cas vert(s), {len(echecs)} echec(s).")
    if echecs:
        print("\nEchecs :")
        for echec in echecs:
            print(f"  - {echec}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
