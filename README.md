# Soumaya

Application Flutter de lecture et de mémorisation du Coran, adossée à la
**Quran Foundation Content API v4**. Rendu du Mushaf de Médine sur 604 pages,
lecture audio verset par verset, répétition paramétrable, compilation par
GitHub Actions.

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
```

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

C'est la CI qui s'en charge, sur un runner `macos-latest`, en build non signé
(`--no-codesign`) : de quoi valider que le projet compile côté Apple, pas de
quoi livrer sur l'App Store.

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
| `.github/workflows/build.yml` | Analyse, tests, APK release, iOS non signé |
| `platform/proxy/` | Proxy de jetons, sans dépendance |
| `tools/lancer_flutter.py` | Lance Flutter depuis Git Bash sous Windows (trois pièges d'environnement, cf. §2) |
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

**Vérifié par exécution**, sur Flutter 3.47.4 / Dart 3.13.3 :

- `flutter analyze` → `No issues found!` ;
- `flutter test` → **55 tests, tous verts** ;
- `flutter build apk --release` → APK produit, puis **ouvert et inspecté**
  (ABI, manifeste, service audio, chaînes de code dans le binaire AOT).

**Vérifié par mesure, sans exécution** : l'équilibrage des délimiteurs des
fichiers Dart, la syntaxe du proxy (analyseur Node), la validité du YAML du
flux et du pubspec, et les versions de chaque paquet via l'API de pub.dev.

**Non vérifié** : le build iOS, impossible depuis Windows — `flutter build ios`
n'y est pas enregistré. C'est la CI, sur `macos-latest`, qui le produira.

**Non vérifié non plus** : le comportement à l'exécution sur un appareil. Rien
n'a été lancé sur un téléphone : ni la lecture audio, ni la synchronisation
verset par verset, ni l'affichage d'une page avec sa police. C'est le premier
essai réel qui le dira, et c'est là qu'il faut s'attendre à des ajustements.

**Restent à faire** : le téléchargement et le cache hors ligne des audio,
l'écran de mémorisation (masquage progressif des mots), et la signature de
l'APK de production (le build de la CI utilise la clé de debug).

---

## 6. Sources

- Portail développeur : <https://api-docs.quran.foundation/>
- Content APIs v4 : <https://api-docs.quran.foundation/docs/content_apis_versioned/4.0.0/content-apis/>
- Endpoint audio par page : `/content/api/v4/recitations/{recitation_id}/by_page/{page_number}`
- Instantané du Mushaf : `/content/api/v4/resources/snapshots/mushafs/{id}`
- OAuth2 : `POST https://oauth2.quran.foundation/oauth2/token`
- Polices et mise en page : <https://qul.tarteel.ai/docs/glyph-based>
