import 'package:flutter/material.dart';

import '../config/app_config.dart';

/// Jetons visuels du Mushaf.
///
/// La teinte papier est volontairement proche du blanc cassé de l'imprimé :
/// un blanc pur produit un contraste dur et fatigue à la lecture longue.
class MushafTheme {
  const MushafTheme._();

  /// Teinte papier naturel.
  static const Color paper = Color(AppConfig.mushafPaperColor);

  /// Encre du texte coranique.
  static const Color ink = Color(0xFF1C1A17);

  /// Filet de l'encadrement calligraphique.
  static const Color frame = Color(0xFFD9CFB8);

  /// Ornement secondaire, plus discret.
  static const Color frameSoft = Color(0xFFEBE3D2);

  /// Fond de la capsule audio, semi-transparent : le flou est appliqué par
  /// `BackdropFilter`, la couleur ne fait que le teinter.
  static const Color capsuleSurface = Color(0xCCFDFBF7);
  static const Color capsuleBorder = Color(0x59FFFFFF);
  static const Color capsuleInk = Color(0xFF2A2622);
  static const Color capsuleAccent = Color(0xFF7A6A4F);

  /// Fond de l'application hors Mushaf.
  static const Color scaffold = Color(0xFFF4F1EA);

  /// Rayon de l'encadrement de page.
  static const double pageRadius = 6;

  /// Marge intérieure entre l'encadrement et la première ligne.
  static const double pageInset = 14;

  /// Proportion de la hauteur de ligne occupée par la police QCF.
  ///
  /// Les polices QCF sont dessinées pour un interlignage serré : une valeur
  /// trop grande fait déborder la dernière ligne hors de la page. Cette valeur
  /// est le point de réglage principal du rendu — elle doit être vérifiée
  /// visuellement contre une page imprimée.
  static const double qcfFontSizeFactor = 0.72;

  /// Opacité de la capsule après quelques secondes d'inactivité.
  static const double capsuleIdleOpacity = 0.34;

  /// Délai avant estompage de la capsule.
  static const Duration capsuleIdleDelay = Duration(seconds: 4);

  /// Durée de fondu des contrôles.
  static const Duration chromeFadeDuration = Duration(milliseconds: 320);

  static const EdgeInsets pagePadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 8,
  );

  static const BorderRadius capsuleRadius = BorderRadius.all(
    Radius.circular(28),
  );
}
