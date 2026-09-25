import 'package:flutter/foundation.dart';

import 'app_config.dart';

/// Enregistre les crédits dus aux tiers dans le registre de licences de Flutter.
///
/// ## Pourquoi c'est une obligation, et pas une politesse
///
/// La Quran Foundation en pose deux, distinctes, et il serait facile de n'en
/// retenir qu'une :
///
///  1. **les polices** — la mise en cache et l'embarquement sont autorisés à
///     deux conditions : détenir un compte Developer Console actif, et créditer
///     « Quran fonts provided by Quran Foundation. » ;
///  2. **le contenu** — « For Connected Apps, display attribution wherever
///     Quranic content is surfaced: “Quran data provided by Quran Foundation.” »
///
/// Les deux formules sont imposées dans les termes mêmes : les reprendre au mot
/// évite d'avoir à discuter d'une paraphrase. Elles ne disent pas la même chose
/// — l'une couvre les fichiers de police, l'autre le texte et les récitations —
/// et c'est pourquoi elles sont enregistrées séparément plutôt que fusionnées.
///
/// ## Pourquoi le registre, et pas un écran écrit à la main
///
/// `LicenseRegistry` est le mécanisme que Flutter prévoit pour cela : les
/// crédits de tous les paquets y sont déjà, `showLicensePage` les affiche, et
/// une entrée ajoutée ici apparaît au même endroit que les autres. Écrire un
/// écran séparé aurait demandé de le tenir à jour pour un résultat moins
/// complet.
///
/// ## Ce que ce fichier ne fait pas
///
/// Il enregistre les crédits, il ne les **rend** pas visibles : c'est le menu
/// du bandeau du Mushaf qui ouvre `showLicensePage`. Les deux obligations sont
/// donc remplies ensemble, par la même entrée.
void enregistrerCredits() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const <String>['Quran Foundation'],
      '${AppConfig.fontCredit}\n\n'
      'Les polices QCF (une par page du Mushaf) et la police Unicode Uthmanic '
      'Hafs sont distribuées par la Quran Foundation et utilisées ici comme '
      'partie intégrante de cette application. Elles ne sont ni revendues, ni '
      'redistribuées séparément, ni proposées en téléchargement autonome.',
    );

    yield LicenseEntryWithLineBreaks(
      const <String>['Quran Foundation — contenu'],
      '${AppConfig.contentCredit}\n\n'
      'Le texte coranique, la mise en page du Mushaf et les récitations audio '
      'proviennent de la Content API v4 de la Quran Foundation et sont affichés '
      'dans le cadre de cette application. Ils ne sont ni revendus, ni '
      'sous-licenciés, ni redistribués séparément.',
    );
  });
}
