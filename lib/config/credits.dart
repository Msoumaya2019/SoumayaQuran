import 'package:flutter/foundation.dart';

import 'app_config.dart';

/// Enregistre les crédits dus aux tiers dans le registre de licences de Flutter.
///
/// ## Pourquoi c'est une obligation, et pas une politesse
///
/// La Quran Foundation autorise la mise en cache et l'embarquement de ses
/// polices **à deux conditions** : détenir un compte Developer Console actif, et
/// créditer la fondation. La seconde est donc aussi contraignante que la
/// première — et c'est la seule des deux qui se voie depuis le code.
///
/// ## Pourquoi le registre, et pas un écran écrit à la main
///
/// `LicenseRegistry` est le mécanisme que Flutter prévoit pour cela : les
/// crédits de tous les paquets y sont déjà, `showLicensePage` les affiche, et
/// une entrée ajoutée ici apparaît au même endroit que les autres. Écrire un
/// écran séparé aurait demandé de le relier à une navigation qui n'existe pas
/// encore, pour un résultat moins complet.
///
/// ## Ce que ce fichier ne fait pas
///
/// Il enregistre le crédit, il ne le **rend** pas visible. Aucun écran de
/// l'application n'ouvre `showLicensePage` à ce jour : la mention n'est donc pas
/// encore accessible à un utilisateur. C'est un point ouvert, consigné dans le
/// README — le crédit est en place, l'entrée qui y mène reste à poser.
void enregistrerCredits() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const <String>['Quran Foundation', 'Polices du Mushaf'],
      '${AppConfig.fontCredit}\n\n'
      'Les polices QCF (une par page du Mushaf) et la police Unicode Uthmanic '
      'Hafs sont distribuées par la Quran Foundation et utilisées ici comme '
      'partie intégrante de cette application. Elles ne sont ni revendues, ni '
      'redistribuées séparément, ni proposées en téléchargement autonome.',
    );
  });
}
