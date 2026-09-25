"""Lanceur Flutter pour Windows / Git Bash.

Pourquoi ce fichier existe : sous Git Bash, `flutter` echoue de trois facons dont
le message n'indique jamais la cause reelle.

1. `flutter.bat` passe par cmd.exe et peut rester suspendu sans rien afficher.
   On appelle donc directement le snapshot Dart.
2. `PATHEXT` n'est pas expose : le paquet `process` lit cette variable sans
   garde et leve « The getter 'split' was called on null ».
3. `PROGRAMFILES(X86)` n'est pas expose : `flutter test` s'arrete sur un
   `throwToolExit` AVANT meme de chercher vswhere. Visual Studio n'est pas
   necessaire, la variable suffit. Bash refuse un nom contenant des
   parentheses, et `env` avale la sortie dans ce bac a sable : on passe donc
   par `subprocess.run(env=...)`, qui accepte n'importe quel nom de variable
   et transmet la sortie.

Usage :
    python tools/lancer_flutter.py --version
    python tools/lancer_flutter.py pub get
    python tools/lancer_flutter.py analyze
    python tools/lancer_flutter.py test
    python tools/lancer_flutter.py build apk --release
"""

import os
import subprocess
import sys
from pathlib import Path

FLUTTER_ROOT = Path(r"C:\Users\mchik\.workbuddy-ai\binaries\flutter")
DART = FLUTTER_ROOT / "bin" / "cache" / "dart-sdk" / "bin" / "dart.exe"
SNAPSHOT = FLUTTER_ROOT / "bin" / "cache" / "flutter_tools.snapshot"

ANDROID_SDK = Path(r"C:\Users\mchik\AppData\Local\Android\Sdk")
JAVA_HOME = Path(r"C:\Program Files\Android\Android Studio\jbr")
PUB_CACHE = Path(r"C:\Users\mchik\.workbuddy-ai\binaries\pub-cache")


def build_env() -> dict:
    env = dict(os.environ)

    # process-5.0.5/common.dart lit PATHEXT sans garde.
    env["PATHEXT"] = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC"

    # flutter test interroge Visual Studio et s'arrete si la variable manque.
    env["PROGRAMFILES"] = r"C:\Program Files"
    env["PROGRAMFILES(X86)"] = r"C:\Program Files (x86)"
    env["ProgramData"] = r"C:\ProgramData"

    env["FLUTTER_ROOT"] = str(FLUTTER_ROOT)
    env["PUB_CACHE"] = str(PUB_CACHE)
    env["JAVA_HOME"] = str(JAVA_HOME)
    env["ANDROID_HOME"] = str(ANDROID_SDK)
    env["ANDROID_SDK_ROOT"] = str(ANDROID_SDK)

    # flutter test pilote flutter_tester par WebSocket sur la boucle locale :
    # un mandataire qui capte 127.0.0.1 fait echouer TOUS les tests d'un coup.
    no_proxy = "127.0.0.1,localhost,::1"
    env["no_proxy"] = no_proxy
    env["NO_PROXY"] = no_proxy

    env["PATH"] = os.pathsep.join(
        [
            str(FLUTTER_ROOT / "bin" / "mingit" / "cmd"),
            r"C:\Program Files\Git\cmd",
            str(FLUTTER_ROOT / "bin"),
            str(JAVA_HOME / "bin"),
            str(ANDROID_SDK / "platform-tools"),
            env.get("PATH", ""),
        ]
    )
    return env


def main(argv: list[str]) -> int:
    if not DART.exists() or not SNAPSHOT.exists():
        print(f"SDK Flutter introuvable sous {FLUTTER_ROOT}", file=sys.stderr)
        return 2

    # `flutter format` n'existe pas : la commande est `dart format`, servie par
    # le meme SDK. On la route vers dart.exe plutot que vers flutter_tools.
    if argv and argv[0] == "dart":
        command = [str(DART), *argv[1:]]
    else:
        command = [str(DART), str(SNAPSHOT), *argv]

    print(f"$ {' '.join(command[1:])}", flush=True)

    # Pas de capture : la sortie doit arriver en direct, un journal vide et un
    # code 0 etant indiscernables d'un succes.
    completed = subprocess.run(command, cwd=Path(__file__).resolve().parent.parent,
                               env=build_env())
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
