#!/usr/bin/env python3
"""Falsifie `verifier_identifiants_qf.py`.

Le banc monte un FAUX amont QF sur la boucle locale — aucun acces reseau externe
— et lance le vrai controle devant lui. Il exige, pour chaque cas, le code de
sortie ET le message, et il verifie dans TOUS les cas que le secret n'apparait
nulle part dans la sortie.

Le cas portant est celui de la rotation : un controle qui refuserait tout
passerait les cas de refus, et un controle qui accepterait tout passerait ceux
d'acceptation. Seul le cas ou le courant est accepte ET l'ancien refuse etablit
que le controle distingue reellement les deux.

Un banc qui sauvegarde puis restaure abime ce qu'il touche : ce banc ne touche
rien dans le depot, il ne fait que lire le controle et verifier son empreinte.

Usage : python tools/banc_verifier_identifiants_qf.py
Code de sortie 0 si tous les cas sont verts, 1 sinon.
"""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import os
import subprocess
import sys
import threading
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
CONTROLE = RACINE / "tools" / "verifier_identifiants_qf.py"

# Secrets factices : jamais de vraie valeur ici.
VIVANT = "qfcs_vivant_0000000000"
ANCIEN_VIVANT = "qfcs_ancien_1111111111"
MORT = "qfcs_mort_2222222222"
RECOPIE = "qfcs_recopie_3333333333"

CLIENT = "11111111-2222-3333-4444-555555555555"

# Secrets que le faux amont accepte. Modifie par cas.
acceptes: set[str] = set()
recopier_dans_erreur = False
# Panne simulee : le proxy d'environnement, lui, rend un 502 quand l'amont est
# injoignable. C'est le cas qui a fait accuser un secret innocent.
panne_serveur = False

verifications = 0
defauts: list[str] = []


def verifier(condition: bool, nom: str, detail: str = "") -> None:
    global verifications
    verifications += 1
    if not condition:
        defauts.append(f"{nom}{' — ' + detail if detail else ''}")


class Amont(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802 — nom impose par BaseHTTPRequestHandler
        longueur = int(self.headers.get("content-length") or 0)
        self.rfile.read(longueur)

        entete = self.headers.get("authorization") or ""
        secret = ""
        if entete.startswith("Basic "):
            try:
                clair = base64.b64decode(entete[6:]).decode("utf-8")
                _, _, secret = clair.partition(":")
            except Exception:
                secret = ""

        if self.path != "/oauth2/token":
            self.repondre(404, {"error": "not_found"})
            return

        if panne_serveur:
            self.repondre(502, {"error": "bad_gateway"})
            return

        if secret in acceptes:
            self.repondre(200, {"access_token": "jeton-factice", "expires_in": 3600,
                                "token_type": "Bearer"})
            return

        corps = {"error": "invalid_client", "error_description": "Client authentication failed"}
        if recopier_dans_erreur and secret:
            corps["echo"] = secret
        self.repondre(401, corps)

    def repondre(self, code: int, corps: dict) -> None:
        donnees = json.dumps(corps).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(donnees)))
        self.end_headers()
        self.wfile.write(donnees)

    def log_message(self, *_: object) -> None:
        """Silence : le banc rend son propre verdict."""


def servir() -> tuple[http.server.ThreadingHTTPServer, str]:
    serveur = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Amont)
    threading.Thread(target=serveur.serve_forever, daemon=True).start()
    return serveur, f"http://127.0.0.1:{serveur.server_port}"


def jouer(base: str, variables: dict[str, str]) -> tuple[int, str]:
    environnement = dict(os.environ)
    for cle in ("QF_CLIENT_ID", "QF_CLIENT_SECRET", "QF_ANCIEN_SECRET", "QF_ENV",
                "QF_AUTH_BASE_URL", "QF_DELAI"):
        environnement.pop(cle, None)
    environnement["QF_AUTH_BASE_URL"] = base
    environnement["QF_DELAI"] = "5"
    environnement.update(variables)

    resultat = subprocess.run(
        [sys.executable, "-u", str(CONTROLE)],
        capture_output=True, text=True, encoding="utf-8", env=environnement, cwd=str(RACINE),
    )
    return resultat.returncode, (resultat.stdout or "") + (resultat.stderr or "")


# Chaque mutation du CONTROLE, et la verification du banc qui doit rougir.
# Une mutation qui n'a pas mute ne prouve rien : le falsificateur le verifie.
MUTATIONS = (
    (
        "le troisieme verdict disparait : une panne redevient un refus",
        "mesurable = code != 0 and code < 500 and code != 429",
        "mesurable = True",
        "502 -> mesure impossible",
    ),
    (
        "l'ancien secret survivant n'est plus un defaut",
        '        if verdicts[ANCIEN]["accepte"]:',
        "        if False:",
        "ancien vivant refuse",
    ),
    (
        "le secret est imprime dans la sortie",
        '    print(f"amont  : {base}")',
        '    print(f"amont  : {base}")\n    print(f"  (secret {secret})")',
        "secret absent de la sortie",
    ),
    (
        "l'empreinte disparait : on ne sait plus QUEL secret a ete teste",
        "f\"empreinte {empreinte(valeur)}  HTTP",
        "f\"HTTP",
        "temoin affiche l'empreinte",
    ),
    (
        "deux secrets identiques ne sont plus refuses",
        "    if ancien and empreinte(ancien) == empreinte(secret):",
        "    if False and ancien and empreinte(ancien) == empreinte(secret):",
        "memes secrets refuses",
    ),
)


# Les deux lignes de la copie du banc qu'il faut repointer vers le controle mute.
# Concatenees a dessein : ecrites d'un seul tenant, elles figureraient DEUX fois
# dans ce fichier — une fois ici, une fois a leur place — et le controle
# d'unicite refuserait a juste titre.
CIBLES_REDIRECTION = (
    "CONTROLE = RACINE " + '/ "tools" / "verifier_identifiants_qf.py"',
    "RACINE = Path(__file__)" + ".resolve().parent.parent",
)


def falsifier() -> int:
    """Mute le CONTROLE dans une copie, et exige que le banc rougisse."""
    import tempfile

    source = CONTROLE.read_text(encoding="utf-8")
    banc_source = Path(__file__).read_text(encoding="utf-8")
    print()
    echecs = 0
    for nom, avant, apres, verification_attendue in MUTATIONS:
        if source.count(avant) != 1:
            echecs += 1
            print(f"  ECHEC  {nom}")
            print(f"        l'ancre est vue {source.count(avant)} fois, attendue 1 — "
                  "la mutation ne peut rien prouver")
            continue

        mute = source.replace(avant, apres, 1)
        if mute == source:
            echecs += 1
            print(f"  ECHEC  {nom}\n        la mutation n'a rien change")
            continue

        with tempfile.TemporaryDirectory() as d:
            dossier = Path(d)
            controle_mute = dossier / "controle_mute.py"
            controle_mute.write_bytes(mute.encode("utf-8"))
            # La racine du banc reste EPOINTEE sur le vrai depot : un banc copie
            # ailleurs et calculant sa racine depuis `__file__` chercherait ses
            # fichiers au mauvais endroit, planterait, et son code de sortie
            # passerait pour un verdict.
            # Chemins en barres obliques, et guillemets DOUBLES dans le texte
            # injecte, chaque cible etant entre guillemets SIMPLES :
            #   * un antislash dans un litteral non brut redevient une sequence
            #     d'echappement (`\U` fait echouer la compilation du fichier genere) ;
            #   * glisser un guillemet identique a celui qui delimite la cible
            #     termine la chaine et casse la ligne.
            if any(banc_source.count(c) != 1 for c in CIBLES_REDIRECTION):
                echecs += 1
                print(f"  ECHEC  {nom}\n        une cible de redirection n'est pas vue une fois : "
                      f"{[(c, banc_source.count(c)) for c in CIBLES_REDIRECTION]}")
                continue

            banc_mute = (banc_source
                         .replace(CIBLES_REDIRECTION[0],
                                  f'CONTROLE = Path("{controle_mute.as_posix()}")')
                         .replace(CIBLES_REDIRECTION[1],
                                  f'RACINE = Path("{RACINE.as_posix()}")'))
            if banc_mute == banc_source:
                echecs += 1
                print(f"  ECHEC  {nom}\n        la copie du banc n'a pas ete redirigee")
                continue
            chemin_banc = dossier / "banc_mute.py"
            chemin_banc.write_bytes(banc_mute.encode("utf-8"))

            resultat = subprocess.run(
                [sys.executable, "-u", str(chemin_banc)],
                capture_output=True, text=True, encoding="utf-8",
            )
            sortie = (resultat.stdout or "") + (resultat.stderr or "")

        rouge = resultat.returncode != 0
        nomme = verification_attendue in sortie
        verdict = "ok  " if (rouge and nomme) else "ECHEC"
        if verdict == "ECHEC":
            echecs += 1
        print(f"  {verdict}  {nom}")
        if verdict == "ECHEC":
            print(f"        le banc a-t-il rougi : {rouge} (code {resultat.returncode})")
            print(f"        verification attendue : {verification_attendue!r}")
            print(f"        sortie : {sortie.strip()[-300:]!r}")

    print(f"\n{len(MUTATIONS) - echecs} mutation(s) detectee(s), {echecs} non detectee(s).")
    return 1 if echecs else 0


def main() -> int:
    # `global` sur TOUS les leviers : sans lui, l'affectation dans `main` cree une
    # variable locale, le serveur ne voit rien changer, et le cas passe pour vert
    # en eprouvant le comportement nominal.
    global acceptes, recopier_dans_erreur, panne_serveur

    avant = hashlib.sha256(CONTROLE.read_bytes()).hexdigest()
    serveur, base = servir()
    sorties: list[tuple[str, str]] = []

    def cas(nom: str, variables: dict[str, str]) -> tuple[int, str]:
        code, sortie = jouer(base, variables)
        sorties.append((nom, sortie))
        return code, sortie

    try:
        # --- temoin : le cas nominal doit PASSER -----------------------------
        acceptes = {VIVANT}
        code, sortie = cas("temoin : couple valide", {
            "QF_CLIENT_ID": CLIENT, "QF_CLIENT_SECRET": VIVANT})
        verifier(code == 0, "temoin accepte", f"code {code} au lieu de 0 — {sortie.strip()[:200]}")
        verifier("empreinte" in sortie, "temoin affiche l'empreinte", sortie.strip()[:200])

        # --- LE cas portant : rotation prouvee -------------------------------
        acceptes = {VIVANT}
        code, sortie = cas("rotation prouvee", {
            "QF_CLIENT_ID": CLIENT, "QF_CLIENT_SECRET": VIVANT, "QF_ANCIEN_SECRET": MORT})
        verifier(code == 0, "rotation prouvee acceptee", f"code {code} — {sortie.strip()[:200]}")
        verifier("Rotation prouvee" in sortie, "rotation nommee", sortie.strip()[:200])

        # --- rotation NON faite : l'ancien survit ----------------------------
        acceptes = {VIVANT, ANCIEN_VIVANT}
        code, sortie = cas("ancien secret encore vivant", {
            "QF_CLIENT_ID": CLIENT, "QF_CLIENT_SECRET": VIVANT,
            "QF_ANCIEN_SECRET": ANCIEN_VIVANT})
        verifier(code == 1, "ancien vivant refuse", f"code {code} — {sortie.strip()[:200]}")
        verifier("[secret-vivant]" in sortie, "marqueur secret-vivant", sortie.strip()[:200])

        # --- secret courant refuse -------------------------------------------
        acceptes = set()
        code, sortie = cas("secret courant refuse", {
            "QF_CLIENT_ID": CLIENT, "QF_CLIENT_SECRET": MORT})
        verifier(code == 1, "courant refuse", f"code {code} — {sortie.strip()[:200]}")
        verifier("[secret-refuse]" in sortie, "marqueur secret-refuse", sortie.strip()[:200])

        # --- ancien identique au courant : la mesure ne dirait rien -----------
        acceptes = {VIVANT}
        code, sortie = cas("ancien identique au courant", {
            "QF_CLIENT_ID": CLIENT, "QF_CLIENT_SECRET": VIVANT, "QF_ANCIEN_SECRET": VIVANT})
        verifier(code == 2, "memes secrets refuses", f"code {code} — {sortie.strip()[:200]}")
        verifier("[memes-secrets]" in sortie, "marqueur memes-secrets", sortie.strip()[:200])

        # --- configuration absente -------------------------------------------
        acceptes = {VIVANT}
        code, sortie = cas("secret non defini", {"QF_CLIENT_ID": CLIENT})
        verifier(code == 2, "configuration signalee", f"code {code} — {sortie.strip()[:200]}")
        verifier("[configuration]" in sortie, "marqueur configuration", sortie.strip()[:200])

        # --- amont injoignable : MESURE IMPOSSIBLE, pas un refus --------------
        # Le premier passage du banc avait trouve ici un vrai defaut : sous un
        # proxy d'environnement, l'amont injoignable remonte en 502, et le
        # controle annoncait « secret refuse » — une fausse accusation.
        acceptes = {VIVANT}
        code, sortie = jouer("http://127.0.0.1:1", {
            "QF_CLIENT_ID": CLIENT, "QF_CLIENT_SECRET": VIVANT})
        sorties.append(("amont injoignable", sortie))
        verifier(code == 2, "amont injoignable -> 2", f"code {code} — {sortie.strip()[:200]}")
        verifier("[mesure-impossible]" in sortie, "marqueur mesure-impossible",
                 sortie.strip()[:200])
        verifier("[secret-refuse]" not in sortie, "pas de fausse accusation",
                 f"un reseau en panne a fait accuser le secret — {sortie.strip()[:200]}")

        # --- l'amont repond 502 : meme chose, par le proxy ---------------------
        acceptes = {VIVANT}
        panne_serveur = True
        code, sortie = cas("l'amont repond 502", {
            "QF_CLIENT_ID": CLIENT, "QF_CLIENT_SECRET": VIVANT})
        verifier(code == 2, "502 -> mesure impossible", f"code {code} — {sortie.strip()[:200]}")
        verifier("[mesure-impossible]" in sortie, "marqueur mesure-impossible (502)",
                 sortie.strip()[:200])
        verifier("[secret-refuse]" not in sortie, "502 n'accuse pas le secret",
                 sortie.strip()[:200])
        panne_serveur = False

        # --- l'amont recopie le secret dans son erreur ------------------------
        acceptes = set()
        recopier_dans_erreur = True
        code, sortie = cas("l'amont recopie le secret", {
            "QF_CLIENT_ID": CLIENT, "QF_CLIENT_SECRET": RECOPIE})
        verifier(code == 1, "fuite amont refusee", f"code {code} — {sortie.strip()[:200]}")
        verifier("[fuite-amont]" in sortie, "marqueur fuite-amont", sortie.strip()[:200])
        recopier_dans_erreur = False

    finally:
        serveur.shutdown()
        serveur.server_close()

    # --- assertion transverse : le secret n'apparait dans AUCUNE sortie ------
    for nom, sortie in sorties:
        for secret in (VIVANT, ANCIEN_VIVANT, MORT, RECOPIE):
            verifier(secret not in sortie, "secret absent de la sortie",
                     f"cas « {nom} » : {secret} apparait")

    # --- le controle n'a pas ete touche --------------------------------------
    apres = hashlib.sha256(CONTROLE.read_bytes()).hexdigest()
    verifier(avant == apres, "le controle est intact",
             f"{avant[:12]} -> {apres[:12]}")

    print()
    for nom, sortie in sorties:
        premiere = next((l for l in sortie.splitlines() if l.strip()), "")
        print(f"  vu    {nom:32} {premiere.strip()[:60]}")

    print(f"\n{verifications} verification(s), {len(defauts)} defaut(s).")
    if defauts:
        print()
        for defaut in defauts:
            print(f"  {defaut}")
        return 1
    print("Aucun defaut.")
    return 0


if __name__ == "__main__":
    if "--falsifier" in sys.argv[1:]:
        raise SystemExit(falsifier())
    raise SystemExit(main())
