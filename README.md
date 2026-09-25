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

Seule `SOUMAYA_QCF_FONT_BASE_URL` a une valeur par défaut utilisable — le CDN
public de la Quran Foundation, celui qui sert réellement les polices. Les deux
autres, `SOUMAYA_PROXY_BASE_URL` et `SOUMAYA_QF_CLIENT_ID`, ne sont pas
renseignées dans ce dépôt et n'ont pas de défaut : sans elles l'application ne
peut joindre ni le proxy de jetons, ni l'API. **Ce binaire établit que la chaîne
de compilation fonctionne ; il ne lit pas encore le Mushaf**, faute de pouvoir
demander la mise en page d'une page. Les polices, elles, se chargeraient.

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
flutter test                  # 58 tests, tous verts

# Les contrôles qui ne demandent ni Flutter ni Mac :
python tools/verifier_flux.py          # le flux de travail est-il bien formé ?
python tools/banc_verifier_flux.py     # et ce contrôle sait-il refuser ?
python tools/banc_defines_dart.py      # les --dart-define partent-ils à bon escient ?
python tools/banc_defines_dart.py --falsifier   # et ce contrôle-là ?
```

`tools/verifier_ipa.py` s'ajoute à cette liste quand un IPA est sous la main :
il lit un fichier livré, il ne peut donc pas tourner avant qu'il existe.

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

⚠️ **N'omettez pas la valeur en laissant la variable vide.** Un `--dart-define`
défini mais vide l'emporte sur le `defaultValue` du code — mesuré : la valeur par
défaut n'est pas seulement ignorée, elle est remplacée par `""`. Passer
`--dart-define=SOUMAYA_QCF_FONT_BASE_URL=` supprime donc l'adresse du CDN au lieu
de la laisser s'appliquer. Si vous ne voulez rien configurer, **n'écrivez pas
l'option du tout**. C'est ce que fait la CI : `tools/defines_dart.py` n'émet que
les variables réellement renseignées, et c'est aussi ce qui l'a rendue
nécessaire — la boucle existait en double, et c'est la copie Android qui avait
gardé le défaut après correction de l'original.

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
| `lib/ui/mushaf_font_provider.dart` | Charge les polices du Mushaf : une par page, plus la police Unicode des marqueurs de fin de verset |
| `lib/config/credits.dart` | Enregistre le crédit exigé par les conditions d'usage des polices |
| `.github/workflows/build.yml` | Contrôle des flux, analyse, tests, APK release, IPA non signé |
| `platform/proxy/` | Proxy de jetons, sans dépendance |
| `tools/lancer_flutter.py` | Lance Flutter depuis Git Bash sous Windows (trois pièges d'environnement, cf. §2) |
| `tools/verifier_flux.py` | Contrôle les flux avant de pousser : YAML, `bash -n` sur chaque `run:`, permissions suffisantes |
| `tools/banc_verifier_flux.py` | Falsifie ce contrôle par 13 mutations, dont deux sur la présence d'un fichier |
| `tools/verifier_ipa.py` | Vérifie un IPA livré sans Mac : plateforme du binaire, signature, code Dart embarqué |
| `tools/banc_verifier_ipa.py` | Falsifie ce contrôle avec de faux IPA — simulateur, plist menteur, code absent |
| `tools/defines_dart.py` | Décide quels `--dart-define` partent en compilation — et n'en passe aucun de vide |
| `tools/banc_defines_dart.py` | Éprouve ce choix dans un environnement fabriqué, puis se falsifie lui-même |
| `.gitattributes` | Fins de ligne figées : la même révision doit se présenter pareil en local et en CI. **Ce n'est pas une exigence de `dart format`** — mesuré, il tolère le CRLF (`Formatted 24 files (0 changed)` sur 51 fichiers en CRLF) ; c'est une exigence de lisibilité et de `diff` |

### Sémantique de la répétition

Deux lectures de « répéter » coexistent en mémorisation, et elles ne donnent
pas le même résultat. Les deux sont implémentées, `RepeatMode` portant le
multiplicateur et `RepeatScope` la portée :

- `perVerse` — chaque verset est répété N fois avant de passer au suivant ;
- `wholeRange` — la plage entière est rejouée N fois.

Dans la capsule : **appui court** sur le bouton de répétition pour parcourir
1x → 2x → 3x → 5x → ∞, **appui long** pour basculer entre verset et plage.

---

## 4. Les polices : où elles sont réellement, et ce que la licence permet

### Une correction

Ce document a d'abord affirmé que « les fichiers de police ne sont pas fournis
par la Content API » — c'est exact — puis en a conclu qu'il fallait les chercher
ailleurs, sur la Quranic Universal Library. **La seconde moitié était fausse.**
Les polices sont bien distribuées par la Quran Foundation, sur un CDN documenté :

```
https://verses.quran.foundation/fonts/quran/hafs/{version}/ttf/p{page}.ttf
```

Quatre faits, tous **mesurés** sur ce CDN et non déduits d'une documentation :

| Fait | Mesure |
|---|---|
| Nom de fichier | `p1.ttf` — **sans** zéro de remplissage. `p001.ttf` et `p01.ttf` répondent **404** |
| Nombre de fichiers | 604 par version ; les 604 répondent **200** |
| Poids total | **198,2 Mio** par version (163 044 à 884 644 octets par page) |
| Versions en TTF | `v1` et `v2` seulement. La `v4` (Tajweed) **n'existe pas en TTF** : `v4/ttf/p1.ttf` répond 404, elle n'est servie qu'en `colrv1` et `ot-svg` |

Le nom sans remplissage mérite d'être souligné : renommer les fichiers en
`p001.ttf` pour « faire propre » produit une page blanche sans message d'erreur.
C'est pourquoi `MushafFontProvider.assetPathForPage` suit le nom du CDN à la
lettre.

`v2` est la version employée, parce que c'est ce que désigne
`default_font_name: "v2"` dans l'instantané du mushaf (`GET
/resources/snapshots/mushafs/1`, qui donne aussi `pages_count: 604` et
`lines_per_page: 15`).

### Les marqueurs de fin de verset

Les polices QCF ne couvrent que le texte coranique. Les marqueurs de fin de
verset — ceux dont `char_type_name` vaut `'end'` — doivent être rendus avec la
police **Unicode** `UthmanicHafs`, un fichier unique de 242 368 octets :

```
https://verses.quran.foundation/fonts/quran/hafs/uthmanic_hafs/UthmanicHafs1Ver18.ttf
```

C'est la recommandation explicite de la documentation de rendu.
`MushafPageCanvas` l'applique **mot par mot** : un même paragraphe mêle donc
deux familles, ce qui interdit de composer un `Text` unique — d'où le passage à
`Text.rich`, la mesure et le rendu partageant la même liste de fragments.

### Ce que la licence autorise, et ce qu'elle interdit

Deux conditions, également contraignantes :

1. détenir un **compte Developer Console actif** ;
2. créditer la fondation — la formule imposée est « **Quran fonts provided by
   Quran Foundation.** »

Et une limite qui vise directement ce dépôt : les fichiers « may be distributed
only as an integrated part of your application » et « may not be offered
separately through your own API, **asset package**, standalone download, or
similar offering ».

**Un dépôt Git public contenant les 604 TTF est exactement un *asset package*** :
il les redistribue séparément de l'application, à quiconque, sans compte ni
crédit. Les fichiers sont donc **ignorés par git** (`.gitignore`), et ce n'est
pas une précaution d'hygiène — c'est ce qui rend l'embarquement licite. Rien
n'est perdu : le CDN du fournisseur est public et documenté, et le dépôt n'a
jamais eu à porter ces fichiers.

Embarquer les 604 fichiers dans le **binaire**, à l'inverse, est autorisé : ils y
seraient intégrés. C'est un choix laissé au développeur — déposez les fichiers
dans `assets/mushaf/qcf2/` et ils seront embarqués. La CI ne les a pas, donc
l'application livrée télécharge à la demande et met en cache sur disque. À
198,2 Mio, c'est aussi le choix qui garde l'APK à 51 Mo plutôt qu'à 250.

### Le crédit

`lib/config/credits.dart` enregistre la mention exigée dans le registre de
licences de Flutter, à l'endroit où sont déjà tous les crédits des paquets.
**Il reste à poser l'entrée qui y mène** : aucun écran n'ouvre
`showLicensePage` aujourd'hui, donc la mention est enregistrée mais pas encore
lisible par un utilisateur. C'est le seul point de licence encore ouvert, et il
faut le traiter avant publication.

### Deux réglages à affiner à l'œil, contre une page imprimée

- `MushafTheme.qcfFontSizeFactor` — proportion de la hauteur de ligne occupée
  par la police ;
- la justification : les lignes sont centrées, pas étirées bord à bord.

---

## 5. Ce qui a été vérifié, et ce qui ne l'a pas été

**Vérifié par exécution en local**, sur Flutter 3.47.4 / Dart 3.13.3 :

- `flutter analyze` → `No issues found!` ;
- `flutter test` → **58 tests, tous verts** ;
- `flutter build apk --release` → APK produit, puis **ouvert et inspecté**
  (ABI, manifeste, service audio, chaînes de code dans le binaire AOT).

**Vérifié par la CI**, premier passage vert du premier coup, trois travaux sur
trois : contrôle des flux (96 vérifications à l'époque), analyse et tests, APK,
IPA.

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

**Les trois contrôles de ce dépôt ont été falsifiés avant d'y croire.** Un
contrôle vert ne prouve rien : ce qui compte est qu'il sache refuser.

- `tools/banc_verifier_flux.py` — 13 cas, dont un témoin. Deux trous trouvés
  dans le contrôle lui-même par le banc, pas par la relecture : PyYAML résout
  `on` en booléen (schéma YAML 1.1) et le contrôle accusait un déclencheur
  absent sur un flux valide ; et la recherche de fermeture d'expression,
  appliquée à du JSON, trouvait les accolades du JSON au lieu de celles de
  l'expression. Le contrôle en compte **102** aujourd'hui.
- `tools/banc_verifier_ipa.py` — 4 cas : compilation de simulateur, binaire de
  simulateur dissimulé sous un `Info.plist` d'appareil, code Dart absent, et un
  témoin qui doit passer.
- `tools/banc_defines_dart.py` — 5 cas exécutés dans un environnement fabriqué,
  plus **3 mutations du contrôle lui-même** : on lui retire l'écartement des
  valeurs vides, puis le refus des valeurs contenant un blanc, puis la rédaction
  du résumé — et il doit rougir à chaque fois. Il ne lit pas de texte, il
  exécute un programme : aucune reformulation ne peut le tromper.

**Vérifié par mesure, sans exécution** : l'équilibrage des délimiteurs des
fichiers Dart, la syntaxe du proxy (analyseur Node), la validité du YAML du
flux et du pubspec, les versions de chaque paquet via l'API de pub.dev, et
**le CDN des polices** — 604 pages sur 604 en HTTP 200, 198,2 Mio au total, le
nom sans zéro de remplissage confirmé par les 404 de `p001.ttf` et `p01.ttf`, et
l'absence de `v4/ttf` établie de même.

**Non vérifié : le comportement à l'exécution sur un appareil.** Rien n'a été
lancé sur un téléphone — ni la lecture audio, ni la synchronisation verset par
verset, ni l'affichage d'une page avec sa police. Le binaire publié établit que
la chaîne de compilation fonctionne de bout en bout ; il ne lit pas encore le
Mushaf. C'est le premier essai réel qui le dira, et c'est là qu'il faut
attendre des ajustements.

**Restent à faire** : l'entrée visible du crédit des polices (§4), le
téléchargement et le cache hors ligne des audio, l'écran de mémorisation
(masquage progressif des mots), et la signature de production de l'APK comme de
l'IPA — les deux sont signés avec des clés de développement.

---

## 6. Sources

- Portail développeur : <https://api-docs.quran.foundation/>
- Content APIs v4 : <https://api-docs.quran.foundation/docs/content_apis_versioned/4.0.0/content-apis/>
- Endpoint audio par page : `/content/api/v4/recitations/{recitation_id}/by_page/{page_number}`
- Instantané du Mushaf : `/content/api/v4/resources/snapshots/mushafs/{id}`
- OAuth2 : `POST https://oauth2.quran.foundation/oauth2/token`
- Rendu des polices — c'est **la** source qui a corrigé le §4 :
  <https://api-docs.quran.foundation/docs/tutorials/fonts/font-rendering/>
- CDN des polices, mesuré ici :
  <https://verses.quran.foundation/fonts/quran/hafs/v2/ttf/p1.ttf>
- Contexte général sur les polices glyph-based :
  <https://qul.tarteel.ai/docs/glyph-based>
