#!/usr/bin/env python3
"""Verifie qu'un couple `client_id` / `client_secret` est accepte par l'amont QF.

Pourquoi ce fichier existe
--------------------------
Le secret a ete divulgue dans une conversation. La rotation est une obligation
contractuelle — Developer Terms §3.2 : « Implement industry-standard security
(e.g., TLS 1.2+, encryption at rest, least-privilege access, secret rotation) ».

Mais une rotation n'est PROUVEE par rien tant qu'on ne l'a pas mesuree. Deux
erreurs symetriques guettent :

  * croire la rotation faite parce qu'on a clique dans la console — or le
    `client_id` et le `client_secret` sont deux chaines distinctes, et l'on peut
    tres bien n'avoir change que l'une ;
  * croire l'ancien secret mort parce que le nouveau fonctionne — c'est le
    contraire qu'il faut etablir.

Ce controle interroge donc le point d'echange reel et rend un verdict par
couple. Lance avec `QF_ANCIEN_SECRET`, il exige les DEUX : le courant accepte,
l'ancien refuse. C'est la seule preuve que la rotation a bien eu lieu.

Le secret n'est jamais affiche — seulement son empreinte SHA-256 tronquee, qui
suffit a verifier qu'on a bien teste deux chaines DIFFERENTES. Le controle
s'auto-verifie : il refuse de conclure si le secret apparait dans ce qu'il
s'apprete a ecrire.

Portee — et un controle de couverture doit dire ou il s'arrete
--------------------------------------------------------------
ATTRAPE : secret refuse (`invalid_client`) ; secret accepte alors qu'il devrait
etre mort ; absence de configuration ; amont injoignable ; reponse qui recopie
le secret ; deux tests qui portent en realite sur le MEME secret.

N'ATTRAPE PAS : si un tiers detient deja le secret expose et s'en sert ; la
portee exacte des scopes accordes au client (le jeton est demande avec
`scope=content`, mais l'amont peut en accorder d'autres) ; la revocation des
jetons DEJA emis avec l'ancien secret — ils restent valides jusqu'a leur
expiration, soit 3600 s.

Usage
-----
    # Verifier le couple courant
    QF_CLIENT_ID=... QF_CLIENT_SECRET=... python tools/verifier_identifiants_qf.py

    # Prouver une rotation : le courant accepte, l'ancien refuse
    QF_CLIENT_ID=... QF_CLIENT_SECRET=<nouveau> QF_ANCIEN_SECRET=<ancien> \\
        python tools/verifier_identifiants_qf.py

    # Interroger le pre-live (sourates 1 et 2 seulement)
    QF_ENV=prelive ... python tools/verifier_identifiants_qf.py

Le secret se passe par l'ENVIRONNEMENT, jamais en argument de ligne de commande
— un argument reste dans l'historique du shell. Le charger depuis un fichier
hors du depot :

    set -a; . ~/.soumaya-qf.env; set +a

Ce controle n'est PAS un portail d'integration continue : il exige de vrais
identifiants, qui n'ont rien a faire dans les secrets d'un depot public.

Codes de sortie : 0 si le verdict attendu est atteint, 1 si un secret est
refuse ou survit, 2 si la mesure est impossible (configuration, reseau).
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

AMONTS = {
    "prod": "https://oauth2.quran.foundation",
    "prelive": "https://prelive-oauth2.quran.foundation",
}

# Les couples a eprouver : nom lisible, variable d'environnement, verdict attendu.
COURANT = "courant"
ANCIEN = "ancien"


def empreinte(secret: str) -> str:
    """Empreinte courte et stable : identifie un secret sans le reveler."""
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()[:12]


def masquer(client_id: str) -> str:
    """Un `client_id` n'est pas un secret, mais rien ne justifie de le recopier."""
    return client_id if len(client_id) <= 8 else f"{client_id[:8]}…"


def demander_jeton(base: str, client_id: str, secret: str, delai: int) -> dict:
    """POST /oauth2/token en Basic. Ne leve pas : rend un verdict structure."""
    identifiants = base64.b64encode(
        f"{client_id}:{secret}".encode("utf-8")).decode("ascii")
    requete = urllib.request.Request(
        f"{base}/oauth2/token",
        data=b"grant_type=client_credentials&scope=content",
        headers={
            "authorization": f"Basic {identifiants}",
            "content-type": "application/x-www-form-urlencoded",
            "accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(requete, timeout=delai) as reponse:
            return {"code": reponse.status, "corps": reponse.read().decode("utf-8", "replace")}
    except urllib.error.HTTPError as erreur:
        return {"code": erreur.code, "corps": erreur.read().decode("utf-8", "replace")}
    except Exception as erreur:  # reseau, DNS, TLS
        return {"code": 0, "corps": str(erreur)}


def code_erreur(corps: str) -> str:
    """Extrait `error` de la reponse, en JSON ou en formulaire."""
    try:
        donnees = json.loads(corps)
        if isinstance(donnees, dict) and donnees.get("error"):
            return str(donnees["error"])
    except ValueError:
        pass
    for morceau in corps.split("&"):
        if morceau.startswith("error="):
            return morceau[len("error="):]
    return ""


def eprouver(base: str, client_id: str, secret: str, delai: int) -> dict:
    """Rend {accepte, mesurable, code, detail, duree} — sans jamais porter le secret.

    TROIS verdicts, pas deux. Un refus et une mesure impossible ne se confondent
    pas : sous un proxy d'environnement, un amont injoignable remonte en `502`,
    et le lire comme un refus ferait dire au controle « votre secret est mort »
    alors que le reseau a echoue. Mesure : c'est exactement ce qui s'est produit
    au premier passage du banc.
    """
    resultat = demander_jeton(base, client_id, secret, delai)
    corps = resultat["corps"]
    code = resultat["code"]

    # Ce qui n'authentifie rien : pas de reponse, erreur serveur, ou quota.
    # Le refus, lui, est un 4xx — sauf 429, qui parle du debit, pas du secret.
    mesurable = code != 0 and code < 500 and code != 429

    # Garde-fou : l'amont ne doit pas nous renvoyer le secret. S'il le fait, on
    # ne l'ecrit pas — on le signale, sans le reproduire.
    if secret and secret in corps:
        return {"accepte": False, "mesurable": mesurable, "code": code, "duree": None,
                "detail": "l'amont a recopie le secret dans sa reponse — contenu non affiche",
                "fuite": True}

    if code == 200:
        duree = None
        try:
            donnees = json.loads(corps)
            if isinstance(donnees, dict):
                duree = donnees.get("expires_in")
        except ValueError:
            pass
        return {"accepte": True, "mesurable": True, "code": 200, "duree": duree,
                "detail": "", "fuite": False}

    if not mesurable:
        raison = "amont injoignable" if code == 0 else f"reponse {code} — mesure impossible"
        return {"accepte": False, "mesurable": False, "code": code, "duree": None,
                "detail": f"{raison} — {corps.strip()[:160]}", "fuite": False}

    return {"accepte": False, "mesurable": True, "code": code, "duree": None,
            "detail": code_erreur(corps) or corps.strip()[:160], "fuite": False}


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv

    client_id = os.environ.get("QF_CLIENT_ID", "")
    secret = os.environ.get("QF_CLIENT_SECRET", "")
    ancien = os.environ.get("QF_ANCIEN_SECRET", "")
    environnement = os.environ.get("QF_ENV", "prod").strip().lower()
    base = os.environ.get("QF_AUTH_BASE_URL") or AMONTS.get(environnement, "")
    delai = int(os.environ.get("QF_DELAI", "20"))

    if "--env" in arguments:
        environnement = arguments[arguments.index("--env") + 1].strip().lower()
        base = AMONTS.get(environnement, "")

    manquants = [n for n, v in (("QF_CLIENT_ID", client_id),
                                ("QF_CLIENT_SECRET", secret)) if not v]
    if manquants:
        print(f"[configuration] {', '.join(manquants)} non defini(s).")
        print("Le secret se passe par l'environnement, jamais en argument :")
        print("  set -a; . ~/.soumaya-qf.env; set +a")
        return 2
    if not base:
        print(f"[configuration] environnement inconnu : {environnement!r} "
              f"(attendu : {', '.join(AMONTS)}), et QF_AUTH_BASE_URL absent.")
        return 2

    print(f"amont  : {base}")
    print(f"client : {masquer(client_id)}")
    print()

    # La rotation se prouve sur DEUX couples, et sur deux chaines differentes.
    if ancien and empreinte(ancien) == empreinte(secret):
        print("[memes-secrets] QF_ANCIEN_SECRET et QF_CLIENT_SECRET sont identiques :")
        print("  le test ne dirait rien de la rotation, il comparerait un secret a lui-meme.")
        return 2

    a_eprouver = [(COURANT, secret, True)]
    if ancien:
        a_eprouver.append((ANCIEN, ancien, False))

    verdicts: dict[str, dict] = {}
    for nom, valeur, doit_etre_accepte in a_eprouver:
        resultat = eprouver(base, client_id, valeur, delai)
        verdicts[nom] = resultat
        if not resultat["mesurable"]:
            obtenu = "non mesurable"
        else:
            obtenu = "accepte" if resultat["accepte"] else "refuse"
        attendu = "accepte" if doit_etre_accepte else "refuse"
        conforme = resultat["mesurable"] and resultat["accepte"] == doit_etre_accepte
        if resultat["accepte"] and resultat.get("duree"):
            detail = f" — jeton valable {resultat['duree']} s"
        else:
            detail = f" — {resultat['detail']}" if resultat["detail"] else ""
        print(f"  {'ok  ' if conforme else 'ECHEC'}  {nom:8} "
              f"empreinte {empreinte(valeur)}  HTTP {resultat['code']:<3} "
              f"attendu {attendu}, obtenu {obtenu}{detail}")

    print()

    # La mesure d'abord : sans elle, il n'y a rien a conclure. Accuser le secret
    # parce que le reseau a echoue serait une fausse accusation.
    if not verdicts[COURANT]["mesurable"]:
        print("[mesure-impossible] le secret courant n'a pas pu etre eprouve :")
        print(f"  {verdicts[COURANT]['detail']}")
        print("  Ce n'est PAS un refus du secret. Verifier le reseau, le proxy")
        print("  d'environnement, puis relancer avant de conclure quoi que ce soit.")
        return 2

    defauts = []
    if not verdicts[COURANT]["accepte"]:
        defauts.append("[secret-refuse] le secret courant est refuse par l'amont")
    if ancien:
        if not verdicts[ANCIEN]["mesurable"]:
            print("[mesure-impossible] l'ancien secret n'a pas pu etre eprouve :")
            print(f"  {verdicts[ANCIEN]['detail']}")
            print("  La rotation n'est donc PAS prouvee — ni infirmee.")
            return 2
        if verdicts[ANCIEN]["accepte"]:
            defauts.append("[secret-vivant] l'ancien secret est ENCORE accepte : "
                           "la rotation n'a pas eu lieu, ou elle n'a porte que sur autre chose")
    for nom, resultat in verdicts.items():
        if resultat.get("fuite"):
            defauts.append(f"[fuite-amont] {nom} — l'amont a recopie le secret")

    if defauts:
        print(f"{len(defauts)} defaut(s) :\n")
        for defaut in defauts:
            print(f"  {defaut}")
        return 1

    if ancien:
        print("Rotation prouvee — le secret courant est accepte, l'ancien est refuse.")
        print("Rappel : les jetons DEJA emis avec l'ancien secret restent valides")
        print("jusqu'a leur expiration (3600 s). La revocation n'est pas instantanee.")
    else:
        print("Le couple est accepte par l'amont.")
        print("Pour PROUVER une rotation, relancer avec QF_ANCIEN_SECRET : l'ancien")
        print("doit etre refuse, sinon il est encore vivant.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
