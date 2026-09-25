# Polices du Mushaf

Ce dossier doit contenir les polices QCF, **une par page du Mushaf** :

```
assets/mushaf/qcf2/p001.ttf
assets/mushaf/qcf2/p002.ttf
...
assets/mushaf/qcf2/p604.ttf
```

## Pourquoi 604 fichiers

Les polices QCF sont *glyph-based* : chaque mot du Coran y est un glyphe unique,
et le jeu complet est dessiné page par page. Il ne s'agit donc pas d'une police
couvrant tout le texte, mais de 604 polices distinctes. Une page sans sa police
ne peut pas être rendue — c'est une contrainte de la typographie d'origine, pas
un choix d'implémentation.

## Où les obtenir

Depuis la [Quranic Universal Library](https://qul.tarteel.ai/), en choisissant
la mise en page **QCF V2** — c'est celle que désigne `default_font_name: "v2"`
dans l'instantané du mushaf renvoyé par la Content API.

## À vérifier avant toute publication

Ces polices ne sont pas libres de droits par défaut. **Vérifiez leurs conditions
de redistribution auprès de leur éditeur avant de les embarquer** dans une
application publiée.

## Alternative

Si vous ne souhaitez pas embarquer 604 fichiers dans le binaire, laissez ce
dossier vide et renseignez plutôt :

```
--dart-define=SOUMAYA_QCF_FONT_BASE_URL=https://votre-cdn/polices
```

`MushafFontProvider` téléchargera alors la police de chaque page à la demande,
avec mise en cache disque. L'application reste utilisable hors ligne pour les
pages déjà consultées.
