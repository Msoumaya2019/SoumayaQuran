# Polices du Mushaf

Ce dossier porte les polices de rendu du Mushaf, et rien d'autre. Les fichiers
eux-mêmes ne sont **pas** versionnés — voir « Pourquoi elles sont ignorées » plus
bas.

## Pourquoi une police par page

Les polices QCF sont *glyph-based* : chaque mot du Coran y est un glyphe unique,
et le jeu complet est dessiné page par page. Ce n'est donc pas une police
couvrant tout le texte, mais **604 polices distinctes**. Une page sans sa police
ne peut pas être rendue — c'est une contrainte de la typographie d'origine, pas
un choix d'implémentation. `MushafFontProvider` en charge une à la demande, et
les garde en mémoire pour la session.

## Où elles sont réellement servies

Le CDN documenté de la Quran Foundation, et **non** la Content API :

```
https://verses.quran.foundation/fonts/quran/hafs/{version}/ttf/p{page}.ttf
```

Quatre faits, tous mesurés sur ce CDN et non déduits d'une documentation :

| Fait | Mesure |
|---|---|
| Nom de fichier | `p1.ttf` — **sans** zéro de remplissage. `p001.ttf` et `p01.ttf` rendent 404. |
| Nombre de fichiers | 604 par version, `p1.ttf` … `p604.ttf`. Les 604 répondent 200. |
| Poids total | **198,2 Mio** pour une version ; de 163 044 à 884 644 octets par page. |
| Versions disponibles en TTF | `v1` et `v2`. La `v4` (Tajweed) **n'existe pas en TTF** — seulement en `colrv1` et `ot-svg`, et son `ttf/` rend 404. |

`v2` est celle qu'emploie ce projet, parce que c'est ce que désigne
`default_font_name: "v2"` dans l'instantané du mushaf renvoyé par la Content API
(`GET /resources/snapshots/mushafs/1`, qui donne aussi `pages_count: 604` et
`lines_per_page: 15`).

## La police Unicode, pour les marqueurs de fin de verset

Les polices QCF ne couvrent que le texte coranique. Les marqueurs de fin de
verset — ceux dont `char_type_name` vaut `'end'` dans l'instantané — doivent être
rendus avec la police **Unicode** `UthmanicHafs`, un fichier unique :

```
https://verses.quran.foundation/fonts/quran/hafs/uthmanic_hafs/UthmanicHafs1Ver18.ttf
```

242 368 octets. C'est la recommandation explicite de la documentation de rendu,
et `MushafPageCanvas` l'applique mot par mot plutôt que de composer un `Text`
unique : un même paragraphe mélange donc deux familles.

## Pourquoi elles sont ignorées

`.gitignore` exclut `*.ttf` de ce dossier. Ce n'est pas une question de poids —
c'est la licence.

Les conditions de la Quran Foundation autorisent la mise en cache et
l'embarquement à deux réserves : disposer d'un **compte Developer Console actif**,
et créditer **« Quran fonts provided by Quran Foundation »**. Elles précisent
surtout que les fichiers « may be distributed only as an integrated part of your
application » et « may not be offered separately through your own API, **asset
package, standalone download**, or similar offering ».

Un dépôt Git public contenant les 604 fichiers est exactement cela : un *asset
package*, redistribué séparément de l'application, à quiconque, sans compte ni
crédit. Les ignorer n'est donc pas une précaution d'hygiène, c'est ce qui rend
l'embarquement licite. Rien n'est perdu : le CDN du fournisseur est public et
documenté, et le dépôt n'a jamais eu à porter ces fichiers.

Embarquer les 604 fichiers dans le binaire, à l'inverse, **est** autorisé — ils y
seraient intégrés. C'est un choix laissé au développeur : déposez les fichiers
ici et ils seront embarqués. La CI, elle, ne les a pas, donc l'application livrée
télécharge à la demande et met en cache sur disque. À 198,2 Mio, c'est aussi le
choix qui garde l'APK à 51 Mo plutôt qu'à 250.

## Comment cela fonctionne à l'exécution

`MushafFontProvider` cherche, pour chaque page, dans cet ordre :

1. l'asset local `assets/mushaf/qcf2/p{page}.ttf` — présent seulement si le
   développeur l'a déposé ;
2. sinon le CDN, à l'URL construite depuis `SOUMAYA_QCF_FONT_BASE_URL` ;
3. puis met le résultat en cache disque, sous `…/fonts/`.

La base du CDN est configurable, mais elle a une valeur par défaut : sans
`--dart-define`, l'application se rabat sur `https://verses.quran.foundation/fonts/quran/hafs`
et fonctionne. Attention en revanche à ne jamais passer ce `--dart-define`
**vide** : une définition vide l'emporte sur la valeur par défaut du code, et
l'application perdrait l'adresse. C'est pourquoi `tools/defines_dart.py` n'émet
que les variables réellement renseignées.
