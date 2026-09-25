import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models/mushaf_layout.dart';
import 'mushaf_font_provider.dart';
import 'mushaf_theme.dart';

/// Rendu d'une page du Mushaf : 15 lignes, encadrement, teinte papier.
///
/// Les mots sont des **glyphes** issus de la police QCF de la page, pas du
/// texte Unicode. La taille de police est donc mesurée puis ajustée pour que
/// la ligne la plus large tienne exactement dans la largeur disponible, au
/// lieu d'être choisie à vue.
class MushafPageCanvas extends StatelessWidget {
  const MushafPageCanvas({
    super.key,
    required this.pageNumber,
    required this.layout,
    required this.fontResult,
  });

  final int pageNumber;

  /// Mise en page reçue de l'instantané `mushafs`. `null` pendant le chargement.
  final MushafPageLayout? layout;

  final MushafFontResult fontResult;

  /// Cache des tailles mesurées, pour éviter de remesurer 15 lignes à chaque
  /// image pendant le défilement horizontal.
  static final Map<String, double> _fontSizeCache = <String, double>{};

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: MushafTheme.paper,
        borderRadius: MushafTheme.capsuleRadius,
        border: Border.all(color: MushafTheme.frame, width: 1.2),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Padding(padding: MushafTheme.pagePadding, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    final page = layout;
    if (page == null) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (!fontResult.isReady) {
      return _MissingFontNotice(pageNumber: pageNumber, layout: page);
    }

    final family = fontResult.family!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final lines = page.lines;
        final lineHeight = constraints.maxHeight / lines.length;
        final fontSize = _fittedFontSize(
          lines: lines,
          family: family,
          maxWidth: constraints.maxWidth,
          maxLineHeight: lineHeight,
        );

        return Column(
          children: <Widget>[
            for (final line in lines)
              SizedBox(
                height: lineHeight,
                child: line.isBlank
                    ? const SizedBox.shrink()
                    : Center(
                        child: Text(
                          line.words.map((word) => word.text).join(' '),
                          maxLines: 1,
                          softWrap: false,
                          textAlign: TextAlign.center,
                          textDirection: TextDirection.rtl,
                          style: TextStyle(
                            fontFamily: family,
                            fontSize: fontSize,
                            height: 1,
                            color: MushafTheme.ink,
                          ),
                        ),
                      ),
              ),
          ],
        );
      },
    );
  }

  /// Taille de police telle que la ligne la plus large occupe [maxWidth],
  /// plafonnée par la hauteur de ligne disponible.
  static double _fittedFontSize({
    required List<MushafLine> lines,
    required String family,
    required double maxWidth,
    required double maxLineHeight,
  }) {
    if (maxWidth <= 0 || maxLineHeight <= 0) return 12;

    final cacheKey =
        '$family|${maxWidth.round()}|${maxLineHeight.round()}'
        '|${lines.map((l) => l.words.length).join(",")}';
    final cached = _fontSizeCache[cacheKey];
    if (cached != null) return cached;

    const base = 100.0;
    var widest = 0.0;

    for (final line in lines) {
      if (line.isBlank) continue;
      final painter = TextPainter(
        text: TextSpan(
          text: line.words.map((word) => word.text).join(' '),
          style: TextStyle(fontFamily: family, fontSize: base, height: 1),
        ),
        textDirection: TextDirection.rtl,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
    }

    final result = widest <= 0
        ? maxLineHeight * MushafTheme.qcfFontSizeFactor
        : math.min(
            base * (maxWidth / widest),
            maxLineHeight * MushafTheme.qcfFontSizeFactor,
          );

    if (_fontSizeCache.length > 512) _fontSizeCache.clear();
    _fontSizeCache[cacheKey] = result;
    return result;
  }
}

/// Affiché quand la police de la page est introuvable.
///
/// On préfère un message explicite à des carrés vides : sans la police QCF de
/// la page, les glyphes n'ont aucun sens et rien ne permettrait de comprendre
/// que le problème vient des polices et non du réseau.
class _MissingFontNotice extends StatelessWidget {
  const _MissingFontNotice({required this.pageNumber, required this.layout});

  final int pageNumber;
  final MushafPageLayout layout;

  @override
  Widget build(BuildContext context) {
    final firstVerse = layout.firstVerseId;
    final lastVerse = layout.lastVerseId;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(
              Icons.font_download_outlined,
              size: 34,
              color: MushafTheme.capsuleAccent,
            ),
            const SizedBox(height: 10),
            Text(
              'Police de la page $pageNumber absente',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MushafTheme.ink,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Versets $firstVerse à $lastVerse \u00b7 '
              '${layout.versesCount} versets',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MushafTheme.capsuleAccent,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Déposez la police dans\n'
              '${MushafFontProvider.assetPathForPage(pageNumber)}\n'
              'ou renseignez SOUMAYA_QCF_FONT_BASE_URL.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: MushafTheme.capsuleAccent,
                fontSize: 10.5,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
