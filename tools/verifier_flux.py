#!/usr/bin/env python3
"""Verifie les flux de travail GitHub Actions avant de les pousser.

Pourquoi ce fichier existe
--------------------------
Un flux de travail se teste normalement en le poussant, et c'est le pire moment
pour decouvrir une faute de frappe : sur ce projet, la compilation iOS installe
Flutter, CocoaPods et Xcode avant d'echouer, et l'aller-retour coute un quart
d'heure. Deux familles de defauts, tres inegales en cout :

  * YAML mal forme          -> le flux ne demarre pas, tout de suite, bruyamment ;
  * script `run:` invalide  -> le flux demarre, echoue apres l'installation
                               complete, et le message ne nomme pas la cause.

C'est la seconde que ce controle attrape, en deux secondes.

Portee — et un controle de couverture doit dire ou il s'arrete
--------------------------------------------------------------
ATTRAPE : YAML invalide ; script refuse par `bash -n` (un `then` manquant, un
`fi` orphelin, une quote non fermee, un extrait multiligne a la colonne 0) ;
declencheur absent ou lu comme un booleen ; action non epinglee ; permissions
absentes, ou insuffisantes pour une etape qui publie une version ; `runs-on`
manquant ; etape qui ne fait rien ; sortie `steps.X.outputs.Y` qu'aucun
producteur n'ecrit.

N'ATTRAPE PAS : une expansion fautive — `${CHEMIN}` mal orthographie passe
`bash -n`, qui analyse sans evaluer. Ni les references `${{ env.X }}` : elles
sont souvent posees a l'execution par `$GITHUB_ENV`, et une analyse statique
les declarerait faussement absentes. Ni rien de ce qui depend de l'executeur —
version d'Xcode, presence de CocoaPods, version de Java.

Usage
-----
    python tools/verifier_flux.py

Code de sortie 0 si aucun defaut, 1 sinon. Chaque defaut porte un marqueur
ASCII entre crochets, pour qu'un banc puisse s'y accrocher sans dependre de
l'encodage ni de la reformulation d'une phrase.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - dependance d'environnement
    print("PyYAML est requis : pip install pyyaml", file=sys.stderr)
    raise SystemExit(2)

# Liste FERMEE. Ce controle est le seul lecteur de ce dossier : sans liste
# fermee, il mesure ce qui reste et jamais ce qui manque, et un flux disparu
# produirait un vert trompeur. Un fichier ajoute doit donc etre declare ici.
FLUX_ATTENDUS = ["build.yml"]

DOSSIER = Path(__file__).resolve().parent.parent / ".github" / "workflows"

TAG_BOOL = "tag:yaml.org,2002:bool"
BOOLEENS_YAML_12 = re.compile(r"^(?:true|True|TRUE|false|False|FALSE)$")


def chargeur_yaml_12() -> type[yaml.SafeLoader]:
    """Analyseur dont les booleens sont ceux de YAML 1.2.

    PyYAML resout `on`, `off`, `yes` et `no` en booleens — c'est le schema
    YAML 1.1. La cle `on:` d'un flux de travail devient donc la cle `True`, et
    un controle qui cherche `"on"` conclut a un declencheur absent sur un flux
    parfaitement valide. GitHub, lui, lit du YAML 1.2 : la cle s'appelle `on`.

    Mesure faite : `yaml.safe_load("on:\\n  push:\\n")` rend `{True: ...}`.
    C'est pourquoi ce chargeur existe, plutot qu'un `yaml.safe_load` direct.
    """

    class Chargeur(yaml.SafeLoader):
        pass

    resolveurs = {
        cle: [(tag, motif) for tag, motif in valeurs if tag != TAG_BOOL]
        for cle, valeurs in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }
    # On ne retire que les formes 1.1 : `true` et `false` restent des booleens.
    for cle in "tTfF":
        resolveurs.setdefault(cle, []).append((TAG_BOOL, BOOLEENS_YAML_12))
    Chargeur.yaml_implicit_resolvers = resolveurs
    return Chargeur


CHARGEUR = chargeur_yaml_12()

verifications = 0
defauts: list[str] = []


def verifier(condition: bool, marqueur: str, message: str) -> None:
    """Compte une verification, et enregistre le defaut si elle echoue."""
    global verifications
    verifications += 1
    if not condition:
        defauts.append(f"{marqueur} {message}")


def neutraliser(script: str) -> str:
    """Remplace les expressions GitHub avant l'analyse du shell.

    Ce n'est PAS ce qui evite un faux positif : `bash -n` tolere `${{ ... }}`,
    mesure faite. C'est une question de fidelite — analyser le texte substitue,
    c'est analyser ce que le shell verra reellement.
    """
    return re.sub(r"\$\{\{[^}]*\}\}", "VALEUR", script)


def expressions_fermees(texte: str) -> bool:
    """Chaque `${{` trouve-t-elle sa fermeture ?

    On ne compare pas les nombres d'ouvertures et de fermetures : le texte
    inspecte est du JSON, qui ferme ses propres accolades, et un comptage
    signalerait des defauts inexistants.
    """
    position = 0
    while True:
        debut = texte.find("${{", position)
        if debut == -1:
            return True
        fin = texte.find("}}", debut + 3)
        if fin == -1:
            return False
        position = fin + 2


def chaines(valeur: object) -> list[str]:
    """Toutes les chaines d'une structure, sans passer par JSON.

    Ne PAS utiliser `json.dumps` pour cela : la serialisation ajoute ses propres
    accolades, et un controle qui cherche `}}` apres un `${{` trouve alors les
    fermetures du JSON lui-meme. Mesure faite — une expression volontairement
    non fermee restait acceptee, pour cette raison exacte, et le banc l'a
    signalee comme « reste vert » alors que le controle paraissait juste.
    """
    if isinstance(valeur, str):
        return [valeur]
    if isinstance(valeur, dict):
        resultat: list[str] = []
        for cle, sous_valeur in valeur.items():
            resultat.extend(chaines(cle))
            resultat.extend(chaines(sous_valeur))
        return resultat
    if isinstance(valeur, list):
        resultat = []
        for sous_valeur in valeur:
            resultat.extend(chaines(sous_valeur))
        return resultat
    return []


def script_refuse(script: str) -> str | None:
    """Rend le message de `bash -n` si le script est invalide, sinon None."""
    resultat = subprocess.run(
        ["bash", "-n", "-c", script],
        capture_output=True,
        text=True,
    )
    if resultat.returncode == 0:
        return None
    return (resultat.stderr or resultat.stdout).strip().splitlines()[0]


def permissions_effectives(job: dict, racine: dict) -> object:
    """Le `permissions` d'un job REMPLACE celui de la racine, il ne s'y ajoute pas."""
    return job.get("permissions", racine.get("permissions"))


def autorise_ecriture(effectives: object) -> bool:
    if effectives == "write-all":
        return True
    if isinstance(effectives, dict):
        return effectives.get("contents") == "write"
    return False


def analyser(nom: str, texte: str) -> None:
    try:
        flux = yaml.load(texte, Loader=CHARGEUR)
    except yaml.YAMLError as erreur:
        verifier(False, "[yaml-invalide]", f"{nom} — {erreur}")
        return

    if not isinstance(flux, dict):
        verifier(False, "[yaml-invalide]", f"{nom} — la racine n'est pas une table.")
        return

    # Le piege du declencheur est reel avec PyYAML, contrairement a js-yaml v4 :
    # `on:` y est resolu en booleen, la cle devient `True`, et le controle
    # conclurait a un declencheur absent. D'ou CHARGEUR, qui lit du YAML 1.2.
    # Ce controle reste en garde : il se declencherait si l'on revenait a
    # `yaml.safe_load`.
    verifier("on" in flux, "[declencheur-absent]", f"{nom} — la cle `on` est absente.")
    if "on" in flux:
        verifier(
            not isinstance(flux["on"], bool),
            "[declencheur-booleen]",
            f"{nom} — `on` est lu comme un booleen : le flux ne se declencherait jamais.",
        )

    verifier(
        "permissions" in flux,
        "[permissions-absentes]",
        f"{nom} — aucun bloc `permissions` a la racine : le jeton recoit plus de droits que necessaire.",
    )

    jobs = flux.get("jobs")
    verifier(isinstance(jobs, dict) and bool(jobs), "[jobs-absents]", f"{nom} — aucun travail.")
    if not isinstance(jobs, dict):
        return

    for nom_job, job in jobs.items():
        if not isinstance(job, dict):
            verifier(False, "[job-invalide]", f"{nom} > {nom_job} — le travail n'est pas une table.")
            continue

        verifier(
            "runs-on" in job,
            "[runs-on-absent]",
            f"{nom} > {nom_job} — `runs-on` est absent.",
        )

        effectives = permissions_effectives(job, flux)

        etapes = job.get("steps")
        verifier(
            isinstance(etapes, list) and bool(etapes),
            "[etapes-absentes]",
            f"{nom} > {nom_job} — aucune etape.",
        )
        if not isinstance(etapes, list):
            continue

        # Un identifiant d'etape connu ne dit pas que la sortie existe : on
        # releve donc aussi ce que chaque producteur ECRIT.
        producteurs: dict[str, set[str]] = {}
        references: list[tuple[str, str]] = []

        for index, etape in enumerate(etapes):
            if not isinstance(etape, dict):
                verifier(
                    False, "[etape-invalide]", f"{nom} > {nom_job} — etape {index + 1} illisible."
                )
                continue

            etiquette = etape.get("name", f"etape {index + 1}")
            emplacement = f"{nom} > {nom_job} > {etiquette}"

            # Les expressions se verifient pour TOUTES les etapes, y compris
            # celles qui ne portent qu'un `uses:` — c'est la que se cachent les
            # references de sortie, et un controle ecrit dans la branche `run:`
            # ne les verrait jamais. On inspecte les chaines une par une, sans
            # passer par JSON : voir `chaines()`.
            champs = chaines(etape)
            verifier(
                all(expressions_fermees(champ) for champ in champs),
                "[expression-non-fermee]",
                f"{emplacement} — une `${{{{` n'a pas de `}}}}` correspondante.",
            )

            identifiant = etape.get("id")
            a_uses = "uses" in etape
            a_run = "run" in etape

            verifier(
                a_uses or a_run,
                "[etape-vide]",
                f"{emplacement} — ni `uses` ni `run` : l'etape ne fait rien.",
            )

            if a_uses:
                action = str(etape["uses"])
                verifier(
                    "@" in action,
                    "[action-non-epinglee]",
                    f"{emplacement} — `{action}` n'est pas epinglee a une version.",
                )

            if a_run:
                script = str(etape["run"])
                refus = script_refuse(neutraliser(script))
                verifier(
                    refus is None,
                    "[script-invalide]",
                    f"{emplacement} — refuse par `bash -n` : {refus}",
                )

                # Une etape qui publie une version a besoin de `contents: write`.
                # Le defaut ne se manifeste qu'a la derniere etape, apres une
                # compilation entiere, et le message parle de permissions — pas
                # de la compilation, qui n'y est pour rien.
                if "gh release create" in script:
                    verifier(
                        autorise_ecriture(effectives),
                        "[permissions-insuffisantes]",
                        f"{emplacement} — publie une version sans `contents: write` "
                        "effectif : le jeton par defaut n'a que la lecture.",
                    )

                if identifiant:
                    for motif in re.finditer(
                        r"""(?:echo|printf)\s+["']?([A-Za-z_][A-Za-z0-9_]*)=.*GITHUB_OUTPUT""",
                        script,
                    ):
                        producteurs.setdefault(str(identifiant), set()).add(motif.group(1))

            if identifiant:
                producteurs.setdefault(str(identifiant), set())

        motif_sortie = re.compile(
            r"steps\.([A-Za-z_][A-Za-z0-9_]*)\.outputs\.([A-Za-z_][A-Za-z0-9_]*)"
        )
        for etape in etapes:
            if not isinstance(etape, dict):
                continue
            for champ in chaines(etape):
                for motif in motif_sortie.finditer(champ):
                    references.append((motif.group(1), motif.group(2)))

        for identifiant, sortie in references:
            if identifiant not in producteurs:
                verifier(
                    False,
                    "[sortie-inconnue]",
                    f"{nom} > {nom_job} — `steps.{identifiant}.outputs.{sortie}` : "
                    f"aucune etape ne porte l'identifiant `{identifiant}`.",
                )
            elif sortie not in producteurs[identifiant]:
                verifier(
                    False,
                    "[sortie-non-declaree]",
                    f"{nom} > {nom_job} — `steps.{identifiant}.outputs.{sortie}` : "
                    f"l'etape `{identifiant}` n'ecrit pas cette sortie.",
                )
            else:
                verifier(True, "", "")


def main(argv: list[str] | None = None) -> int:
    # Le dossier est parametrable pour que le banc puisse viser une copie
    # temporaire, et falsifier le controle sans jamais muter les vrais
    # fichiers : un banc qui sauvegarde puis restaure abime ce qu'il touche
    # (`write_text` traduit `\n` en `\r\n` sous Windows).
    arguments = sys.argv[1:] if argv is None else argv
    dossier = Path(arguments[0]).resolve() if arguments else DOSSIER

    if not dossier.is_dir():
        print(f"[dossier-absent] {dossier} n'existe pas.", file=sys.stderr)
        return 1

    presents = sorted(
        chemin.name
        for chemin in dossier.iterdir()
        if chemin.suffix in {".yml", ".yaml"} and chemin.is_file()
    )

    # Les deux sens : un fichier manquant doit echouer, et un fichier ajoute
    # non declare doit echouer aussi. Sans le second, une garde qui refuserait
    # tout passerait pour concluante.
    for nom in FLUX_ATTENDUS:
        verifier(nom in presents, "[flux-absent]", f"{nom} — flux attendu absent du dossier.")
    for nom in presents:
        verifier(
            nom in FLUX_ATTENDUS,
            "[flux-non-declare]",
            f"{nom} — present mais non declare dans FLUX_ATTENDUS.",
        )

    for nom in presents:
        if nom not in FLUX_ATTENDUS:
            continue
        analyser(nom, (dossier / nom).read_text(encoding="utf-8"))

    print(
        f"{len(FLUX_ATTENDUS)} flux attendu(s), {len(presents)} present(s), "
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
