# Soumaya

Application Flutter de lecture et de mémorisation du Coran, adossée à la
**Quran Foundation Content API v4**. Rendu du Mushaf de Médine sur 604 pages,
lecture audio verset par verset, répétition paramétrable, compilation par
GitHub Actions.

Dépôt : <https://github.com/Msoumaya2019/SoumayaQuran>

## Livraison

| | |
|---|---|
| **IPA iOS**, non signé, pour appareil | [version 0.1.0](https://github.com/Msoumaya2019/SoumayaQuran/releases/tag/v0.1.0) — 7 238 020 octets |
| **APK Android** release | artefact `soumaya-apk` du dernier passage de la CI |

L'IPA **ne s'installe pas tel quel** : iOS refuse tout binaire non signé. Il se
re-signe, puis s'installe — les trois murs à franchir sont détaillés au §2,
section « Re-signer l'IPA ».

Les variables `SOUMAYA_PROXY_BASE_URL`, `SOUMAYA_QF_CLIENT_ID` et
`SOUMAYA_QCF_FONT_BASE_URL` ne sont pas renseignées dans ce dépôt. L'application
démarre, mais ne peut joindre ni le proxy de jetons, ni l'API, et n'a aucune
police QCF pour rendre une page. **Ce binaire établit que la chaîne de
compilation fonctionne ; il ne lit pas encore le Mushaf.**

---

## 1. À lire en premier : trois points des spécifications initiales ne
## correspondent pas à ce que l'API permet

Ces trois écarts ont été vérifiés dans la documentation officielle
(`api-docs.quran.foundation`) et conditionnent l'architecture. Les ignorer
aurait produit une application qui compile mais ne lit rien.

### 1.1 L'authentification n'est pas une clé d'API, et elle interdit le secret embarqué

La Content API n'accepte que le grant **`client_credentials`**, avec le scope
`content`. Le flux Authorization Code + PKCE est réservé aux User APIs.

Conséquence directe : il faut un **client confidentiel**, donc un
`client_secret`. Or un secret compilé dans un APK est extractible en quelques
minutes — il donnerait à n'importe qui le contrôle du quota du projet.

Le projet est donc bâti autour d'un **proxy** (`platform/proxy/`) qui détient
seul le secret et délivre des jetons d'une heure. L'application ne connaît que
l'URL du proxy et le `client_id`, qui n'est pas un secret.

Un garde-fou empêche de contourner cette règle par inadvertance : la classe
`ClientCredentialsTokenSource` refuse de s'instancier en mode release tant que
`SOUMAYA_ALLOW_EMBEDDED_CREDENTIALS` n'a pas été activé explicitement.

### 1.2 `/pages/{n}` ne renvoie aucun numéro de ligne — le rendu fidèle passe ailleurs

Le chemin le plus évident pour reconstituer une page est
`GET /content/api/v4/pages/{page_number}`. Il renvoie bien `verse_mapping`,
`first_verse_id`, `last_verse_id` et `verses_count`, mais **pas** la position
des mots : la grille de 15 lignes n'y figure pas.

Le rendu ligne à ligne vient du groupe de ressources **`mushafs`** :
`GET /content/api/v4/resources/snapshots/mushafs/1` renvoie des
enregistrements `mushaf_word` portant `line_number`, `position_in_line`,
`position_in_page` et `text`. Les métadonnées confirment `lines_per_page: 15`,
`pages_count: 604` et `default_font_name: "v2"`.

En prime, ce même instantané fournit `first_verse_id` / `last_verse_id` par
page, qui servent à bâtir l'index verset → page **hors ligne**.

### 1.3 Yasser Al-Dossari n'apparaît pas dans le catalogue documenté

Le catalogue officiel documenté contient Al-Afasy (identifiant **7**) et
Minshawi (**8** en Mujawwad, **9** en Murattal), mais **aucune entrée pour
Yasser Al-Dossari**.

Aucun identifiant n'est donc écrit en dur. Les récitateurs sont résolus par
leur nom à l'exécution (`lib/data/reciter_catalog.dart`), avec une
correspondance tolérante aux variantes d'orthographe — « Mishary » demandé,
« Mishari » renvoyé. Un récitateur introuvable est **signalé comme
indisponible** dans l'interface au lieu de produire un lecteur muet.

### 1.4 Deux détails qui font perdre des versets en silence

- `per_page` vaut **10 par défaut** sur l'endpoint audio, et plafonne à 50. Une
  page du Mushaf peut porter davantage de versets : la valeur est forcée à 50,
  et la pagination est parcourue jusqu'à épuisement.
- L'API renvoie l'URL audio tantôt absolue, tantôt **relative**
  (`AbdulBaset/Mujawwad/mp3/001001.mp3`) — les deux formes figurent dans la
  documentation. Les deux sont normalisées vers `verses.quran.foundation`.

---

## 2. Démarrage

Le squelette de plateforme est en place et le projet **compile** : `android/`
et `ios/` sont versionnés, les trois fichiers de plateforme décrits en
`platform/` ont été appliqués aux vrais fichiers (ils n'y restent qu'à titre
de référence, pour relire ce qui a été modifié et pourquoi).

```bash
flutter pub get
dart format lib test          # avant l'analyse, pas après
flutter analyze               # No issues found!
flutter test                  # 55 tests, tous verts

# Les deux contrôles qui ne demandent ni Flutter ni Mac :
python tools/verifier_flux.py        # le flux de travail est-il bien formé ?
python tools/banc_verifier_flux.py   # et ce contrôle sait-il refuser ?
```

Le contrôle des flux passe **en premier dans la CI**, avant l'installation de
Flutter : il coûte deux secondes, là où une faute de frappe dans un script
`run:` ne se verrait qu'après l'installation complète, avec un message qui ne
nomme pas la cause.

`dart format` en premier n'est pas cosmétique : la mise en forme peut *créer*
des avertissements `curly_braces_in_flow_control_structures` en repliant un
`if` sur une ligne, et l'analyse échoue alors sur du code qu'on vient
d'écrire. (Il n'existe pas de `flutter format`.)

### Compiler l'Android

```bash
flutter build apk --release \
  --dart-define=SOUMAYA_PROXY_BASE_URL=https://votre-proxy \
  --dart-define=SOUMAYA_QF_CLIENT_ID=votre_client_id \
  --dart-define=SOUMAYA_QCF_FONT_BASE_URL=https://votre-cdn/polices
```

Produit `build/app/outputs/flutter-apk/app-release.apk` — **51 298 401 octets
(≈ 49 Mo)** sur la machine de référence, trois ABI embarquées (arm64-v8a,
armeabi-v7a, x86_64), `minSdk 24`, `targetSdk 36`.

Le paquet a été ouvert et vérifié, pas seulement « construit sans erreur » :
archive ZIP valide, `libapp.so` présent par ABI, service `AudioService`
déclaré avec `foregroundServiceType=mediaPlayback`, `MediaButtonReceiver`
présent, les quatre permissions audio au manifeste, et les chaînes de code
(`apis.quran.foundation`, `by_page`, `snapshots/mushafs`) retrouvées dans le
binaire AOT.

**Ce paquet est signé avec la clé de débogage** (`CN=Android Debug`) : il
s'installe pour essayer, il ne se publie pas. La signature de production reste
à faire.

### Compiler l'iOS

**Impossible depuis Windows, et ce n'est pas une question de configuration :**
`flutter build ios` n'existe pas sur cette plateforme, la sous-commande n'étant
enregistrée que sur macOS. Mesuré — `flutter build -h` ne propose ici que
`aar`, `apk`, `appbundle`, `bundle`, `web` et `windows`.

C'est la CI qui s'en charge, sur un runner `macos-latest`, et c'est la seule
voie : `flutter build ios --release --no-codesign` produit un bundle **pour
appareil**, que le flux empaquette ensuite en IPA.

Mesuré au premier passage, run vert du premier coup : Xcode 26.6, compilation
Xcode en 58,6 s, `Runner.app` de 17,2 Mo, IPA de **7 238 020 octets**.

Le flux ne se contente pas de compiler — il **vérifie ce qu'il a produit**, et
refuse de publier l'artefact si l'un des contrôles tombe :

| Contrôle | Ce qu'il attrape |
|---|---|
| `DTPlatformName` = `iphoneos` | une compilation de **simulateur**, qui a la forme d'un IPA et ne s'installera sur aucun iPhone, même signée |
| `CFBundleSupportedPlatforms` = `iPhoneOS` | le même défaut, par un second témoin indépendant |
| `LC_BUILD_VERSION` du binaire, plateforme 2 | le même défaut encore, cette fois lu dans l'en-tête Mach-O — l'un des trois témoins peut manquer selon la forme du fichier |
| `CFBundleIdentifier` = `fr.fcpe.montmagny.soumaya` | un paquet qui ne serait pas celui du projet |
| absence de `embedded.mobileprovision` | un paquet présenté comme non signé, mais qui le serait |

Ce dernier contrôle a une limite qu'il faut connaître : l'absence de profil
prouve que le paquet n'est **pas signé**, elle ne prouve **pas** qu'il vise un
appareil — une compilation `iphoneos` non signée en est dépourvue aussi. C'est
le contrôle de plateforme qui tranche, et lui seul.

### Re-signer l'IPA, puis l'installer

**Un IPA non signé ne s'installe pas.** iOS refuse tout binaire sans signature.
Le fichier est un produit intermédiaire : il se re-signe (Sideloadly, AltStore,
eSign) depuis Windows comme depuis macOS, puis s'installe.

Trois murs, chacun produisant un message qui ne nomme pas sa cause :

1. **Mode développeur obligatoire** depuis iOS 16 — Réglages →
   Confidentialité et sécurité → Mode développeur, puis redémarrer. Sans lui,
   l'installation échoue ou l'application refuse de s'ouvrir. Le projet vise
   iOS 15.0 au minimum, donc ce mode est requis dès qu'un appareil est en 16
   ou plus.
2. **Sous Windows, iTunes doit venir du site d'Apple**, pas du Microsoft Store :
   la version du Store n'installe pas les pilotes Apple Mobile Device, et
   l'outil répond `No devices detected`.
3. **Avec un compte Apple gratuit, il faut le mot de passe principal** de
   l'identifiant Apple, et non un mot de passe d'application : celui-ci n'est
   accepté qu'avec un compte développeur payant. Puis, sur l'iPhone, accepter
   **Faire confiance** (Réglages → Général → VPN et gestion de l'appareil).

Limites d'un compte gratuit, à connaître avant de commencer : 7 jours de
validité, 3 applications simultanées, 10 identifiants d'application par tranche
de 7 jours.

### Le proxy

```bash
cd platform/proxy
QF_CLIENT_ID=... QF_CLIENT_SECRET=... node qf-token-proxy.mjs
```

Sans dépendance. Limitation assumée et documentée dans l'en-tête du fichier :
il protège le *secret*, pas le *quota*. Le jeton délivré ne porte que le scope
`content`, en lecture seule, et une limite de débit par IP est appliquée.

### Le lanceur local, et pourquoi il existe

`tools/lancer_flutter.py` lance Flutter depuis Git Bash sous Windows. Trois
pièges d'environnement le justifient, tous vérifiés :

1. `flutter.bat` se bloque quand il est appelé ainsi — le lanceur appelle
   directement l'instantané Dart.
2. `PATHEXT` absent casse `package:process` (`NoSuchMethodError`).
3. `PROGRAMFILES(X86)` absent fait échouer `flutter test` sur un
   `throwToolExit` dans `visual_studio.dart`, **avant même** d'avoir cherché
   `vswhere` — alors que Visual Studio n'est pas nécessaire.

Il neutralise aussi le proxy sur la boucle locale (`no_proxy`), sans quoi
`flutter_tester` ne parvient pas à ouvrir son WebSocket.

---

## 3. Ce que contient le dépôt

| Fichier | Rôle |
|---|---|
| `pubspec.yaml` | Dépendances, contrainte Flutter ≥ 3.27 (imposée par just_audio 0.10) |
| `lib/data/quran_api_service.dart` | Client Content API v4 : récitateurs, audio par page, plage de versets, instantané du Mushaf, cache disque |
| `lib/data/qf_token_provider.dart` | Jeton OAuth2, cache, appel unique en vol, refus du secret embarqué en release |
| `lib/data/reciter_catalog.dart` | Résolution des récitateurs par nom, tolérante à l'orthographe |
| `lib/data/models/` | `AudioFile`, `Recitation`, `VerseKey` + table d'ordinaux, mise en page du Mushaf, index verset → page |
| `lib/audio/playback_plan.dart` | Moteur de répétition, en Dart pur donc testable sans appareil |
| `lib/audio/audio_controller.dart` | File d'attente, `audio_service`, notification et écran verrouillé |
| `lib/ui/mushaf_page_view.dart` | Écran plein écran, `PageView(reverse: true)`, capsule flottante |
| `lib/ui/mushaf_page_canvas.dart` | Rendu des 15 lignes, taille de police mesurée |
| `lib/ui/audio_capsule.dart` | Capsule `BackdropFilter`, estompage automatique |
| `lib/ui/mushaf_font_provider.dart` | Charge les 604 polices QCF, une par page |
| `.github/workflows/build.yml` | Contrôle des flux, analyse, tests, APK release, IPA non signé |
| `platform/proxy/` | Proxy de jetons, sans dépendance |
| `tools/lancer_flutter.py` | Lance Flutter depuis Git Bash sous Windows (trois pièges d'environnement, cf. §2) |
| `tools/verifier_flux.py` | Contrôle les flux avant de pousser : YAML, `bash -n` sur chaque `run:`, permissions suffisantes |
| `tools/banc_verifier_flux.py` | Falsifie ce contrôle par 13 mutations, dont deux sur la présence d'un fichier |
| `tools/verifier_ipa.py` | Vérifie un IPA livré sans Mac : plateforme du binaire, signature, code Dart embarqué |
| `tools/banc_verifier_ipa.py` | Falsifie ce contrôle avec de faux IPA — simulateur, plist menteur, code absent |
| `.gitattributes` | Fins de ligne figées : `dart format` compare des octets, et la CI n'a pas le même `core.autocrlf` que la machine locale |

### Sémantique de la répétition

Deux lectures de « répéter » coexistent en mémorisation, et elles ne donnent
pas le même résultat. Les deux sont implémentées, `RepeatMode` portant le
multiplicateur et `RepeatScope` la portée :

- `perVerse` — chaque verset est répété N fois avant de passer au suivant ;
- `wholeRange` — la plage entière est rejouée N fois.

Dans la capsule : **appui court** sur le bouton de répétition pour parcourir
1x → 2x → 3x → 5x → ∞, **appui long** pour basculer entre verset et plage.

---

## 4. Le point à trancher avant de livrer : les polices

C'est le seul élément que ce dépôt ne peut pas fournir.

Les polices QCF sont **glyph-based** : chaque mot est un glyphe unique, et le
jeu est dessiné **page par page**. Il faut donc **604 fichiers de police**, un
par page — ce n'est pas une police couvrant tout le texte. La Content API ne
les sert pas : l'instantané `mushafs` ne renvoie que le nom de famille attendu
(`v2`).

`MushafFontProvider` essaie trois sources dans l'ordre : asset local
`assets/mushaf/qcf2/pXXX.ttf`, puis téléchargement depuis
`SOUMAYA_QCF_FONT_BASE_URL` avec mise en cache, puis rien. Dans ce dernier cas
la page affiche un message explicite nommant le fichier manquant — jamais des
carrés vides.

**À faire avant toute publication** : vérifier les conditions de
redistribution de ces polices auprès de leur éditeur, et les télécharger depuis
la [Quranic Universal Library](https://qul.tarteel.ai/) (mise en page QCF V2,
celle que désigne `default_font_name: "v2"`).

Deux autres réglages restent à affiner à l'œil, contre une page imprimée :

- `MushafTheme.qcfFontSizeFactor` — proportion de la hauteur de ligne occupée
  par la police ;
- la justification : les lignes sont centrées, pas étirées bord à bord.

---

## 5. Ce qui a été vérifié, et ce qui ne l'a pas été

**Vérifié par exécution en local**, sur Flutter 3.47.4 / Dart 3.13.3 :

- `flutter analyze` → `No issues found!` ;
- `flutter test` → **55 tests, tous verts** ;
- `flutter build apk --release` → APK produit, puis **ouvert et inspecté**
  (ABI, manifeste, service audio, chaînes de code dans le binaire AOT).

**Vérifié par la CI**, premier passage vert du premier coup, trois travaux sur
trois : contrôle des flux (96 vérifications), analyse et tests, APK, IPA.

**Vérifié sur le fichier publié, après retéléchargement anonyme** — c'est le
seul contrôle qui vaille pour une livraison :

| Contrôle | Résultat |
|---|---|
| Téléchargement sans authentification | HTTP **200**, 7 238 020 octets |
| Empreinte du fichier publié | `4cbe9a2c3811cd95dfabca8b931054dab965481ab35ef3bc0c8c6e07e3fad214`, identique à l'octet près au fichier vérifié |
| `DTPlatformName` | `iphoneos` |
| `CFBundleSupportedPlatforms` | `['iPhoneOS']` |
| `LC_BUILD_VERSION` (Mach-O, binaire mince) | plateforme 2 → iOS, **appareil** |
| `_CodeSignature` / `embedded.mobileprovision` | 0 entrée / absent — non signé, comme attendu |
| Chaînes du code dans l'instantané Dart | 4 sur 4 |

Un artefact de flux de travail, lui, répond **401** à un téléchargement
anonyme : c'est ce qui justifie la version publiée plutôt que le seul artefact.

**Les deux contrôles de ce dépôt ont été falsifiés avant d'y croire.** Un
contrôle vert ne prouve rien : ce qui compte est qu'il sache refuser.

- `tools/banc_verifier_flux.py` — 13 cas, dont un témoin. Deux trous trouvés
  dans le contrôle lui-même par le banc, pas par la relecture : PyYAML résout
  `on` en booléen (schéma YAML 1.1) et le contrôle accusait un déclencheur
  absent sur un flux valide ; et la recherche de fermeture d'expression,
  appliquée à du JSON, trouvait les accolades du JSON au lieu de celles de
  l'expression.
- `tools/banc_verifier_ipa.py` — 4 cas : compilation de simulateur, binaire de
  simulateur dissimulé sous un `Info.plist` d'appareil, code Dart absent, et un
  témoin qui doit passer.

**Vérifié par mesure, sans exécution** : l'équilibrage des délimiteurs des
fichiers Dart, la syntaxe du proxy (analyseur Node), la validité du YAML du
flux et du pubspec, et les versions de chaque paquet via l'API de pub.dev.

**Non vérifié : le comportement à l'exécution sur un appareil.** Rien n'a été
lancé sur un téléphone — ni la lecture audio, ni la synchronisation verset par
verset, ni l'affichage d'une page avec sa police. Le binaire publié établit que
la chaîne de compilation fonctionne de bout en bout ; il ne lit pas encore le
Mushaf. C'est le premier essai réel qui le dira, et c'est là qu'il faut
attendre des ajustements.

**Restent à faire** : l'obtention des 604 polices QCF (le point bloquant, §4),
le téléchargement et le cache hors ligne des audio, l'écran de mémorisation
(masquage progressif des mots), et la signature de production de l'APK comme de
l'IPA — les deux sont signés avec des clés de développement.

---

## 6. Sources

- Portail développeur : <https://api-docs.quran.foundation/>
- Content APIs v4 : <https://api-docs.quran.foundation/docs/content_apis_versioned/4.0.0/content-apis/>
- Endpoint audio par page : `/content/api/v4/recitations/{recitation_id}/by_page/{page_number}`
- Instantané du Mushaf : `/content/api/v4/resources/snapshots/mushafs/{id}`
- OAuth2 : `POST https://oauth2.quran.foundation/oauth2/token`
- Polices et mise en page : <https://qul.tarteel.ai/docs/glyph-based>
