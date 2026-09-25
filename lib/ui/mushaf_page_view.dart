import 'dart:async';

import 'package:flutter/material.dart';

import '../app/soumaya_session.dart';
import '../config/app_config.dart';
import '../data/reciter_catalog.dart';
import 'audio_capsule.dart';
import 'mushaf_font_provider.dart';
import 'mushaf_page_canvas.dart';
import 'mushaf_theme.dart';

/// Écran de lecture : le Mushaf plein écran, feuilleté de droite à gauche.
///
/// Aucun en-tête ni barre d'onglets ne reste affiché : la page occupe tout
/// l'écran. Un simple appui masque ou rappelle les contrôles, qui s'estompent
/// d'eux-mêmes après quelques secondes.
class MushafPageView extends StatefulWidget {
  const MushafPageView({super.key, required this.session});

  final SoumayaSession session;

  @override
  State<MushafPageView> createState() => _MushafPageViewState();
}

class _MushafPageViewState extends State<MushafPageView> {
  late final PageController _pageController;

  final Map<int, MushafFontResult> _fonts = <int, MushafFontResult>{};
  final Set<int> _fontsPending = <int>{};

  /// Les contrôles sont-ils appelés par l'utilisateur ?
  bool _chromeVisible = true;

  /// Opacité effective de la capsule : réduite après inactivité.
  double _capsuleOpacity = 1;

  Timer? _idleTimer;
  int _visiblePage = 1;

  @override
  void initState() {
    super.initState();
    // `reverse: true` sur la PageView assure le feuilletage de droite à gauche,
    // comme un Coran physique. L'index 0 reste la page 1 du Mushaf.
    _pageController = PageController(initialPage: 0);
    widget.session.addListener(_onSessionChanged);
    _preloadFontsAround(1);
    _restartIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    widget.session.removeListener(_onSessionChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Estompage automatique
  // ---------------------------------------------------------------------------

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(MushafTheme.capsuleIdleDelay, () {
      if (!mounted) return;
      setState(() => _capsuleOpacity = MushafTheme.capsuleIdleOpacity);
    });
  }

  /// Signalé à chaque interaction avec les contrôles.
  void _markInteraction() {
    if (_capsuleOpacity != 1) {
      setState(() => _capsuleOpacity = 1);
    }
    _restartIdleTimer();
  }

  /// Un appui sur la page masque ou rappelle les contrôles.
  void _toggleChrome() {
    setState(() {
      _chromeVisible = !_chromeVisible;
      _capsuleOpacity = _chromeVisible ? 1 : 0;
    });
    if (_chromeVisible) _restartIdleTimer();
  }

  // ---------------------------------------------------------------------------
  // Polices
  // ---------------------------------------------------------------------------

  /// Charge la police de [page] et de ses voisines immédiates.
  ///
  /// Précharger une page de chaque côté évite d'afficher un état de chargement
  /// au moment précis où l'utilisateur fait glisser la page.
  void _preloadFontsAround(int page) {
    for (final candidate in <int>[page - 1, page, page + 1]) {
      _ensureFont(candidate);
    }
  }

  void _ensureFont(int page) {
    if (page < 1 || page > AppConfig.mushafPageCount) return;
    if (_fonts.containsKey(page) || _fontsPending.contains(page)) return;

    _fontsPending.add(page);
    unawaited(
      widget.session.fontProvider.resolve(page).then((result) {
        _fontsPending.remove(page);
        if (!mounted) return;
        setState(() => _fonts[page] = result);
      }),
    );
  }

  MushafFontResult? _fontFor(int page) => _fonts[page];

  // ---------------------------------------------------------------------------
  // Feuilletage
  // ---------------------------------------------------------------------------

  void _onPageChanged(int index) {
    final page = index + 1;
    _visiblePage = page;
    _preloadFontsAround(page);
    // On suit la page feuilletée : si une écoute est en cours, elle se poursuit
    // sur la nouvelle page ; sinon la file est seulement préparée.
    unawaited(
      widget.session.openPage(page, autoPlay: widget.session.audio.isPlaying),
    );
    _markInteraction();
  }

  // ---------------------------------------------------------------------------
  // Sélecteurs
  // ---------------------------------------------------------------------------

  Future<void> _openRangeSelector() async {
    final page = _visiblePage;
    final keys = widget.session.verseKeysOfPage(page);
    if (keys.isEmpty) return;

    final selection = await showModalBottomSheet<({String? from, String? to})>(
      context: context,
      backgroundColor: MushafTheme.paper,
      showDragHandle: true,
      builder: (context) => _RangeSheet(verseKeys: keys),
    );

    if (selection == null) return;
    try {
      await widget.session.applyRange(from: selection.from, to: selection.to);
    } on Object catch (error) {
      _showMessage(error.toString());
    }
    _markInteraction();
  }

  Future<void> _openReciterSelector() async {
    final chosen = await showModalBottomSheet<ReciterResolution>(
      context: context,
      backgroundColor: MushafTheme.paper,
      showDragHandle: true,
      builder: (context) => _ReciterSheet(
        resolutions: widget.session.reciters,
        selected: widget.session.selectedReciter,
      ),
    );

    if (chosen == null) return;
    await widget.session.selectReciter(chosen);
    _markInteraction();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  // ---------------------------------------------------------------------------
  // Rendu
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final session = widget.session;

    return Scaffold(
      backgroundColor: MushafTheme.scaffold,
      body: SafeArea(
        child: switch (session.status) {
          SessionStatus.idle || SessionStatus.loading => const Center(
            child: CircularProgressIndicator(),
          ),
          SessionStatus.failed => _FailureView(
            message: session.errorMessage ?? 'Démarrage impossible.',
            onRetry: session.initialize,
          ),
          SessionStatus.ready => Stack(
            children: <Widget>[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleChrome,
                  child: PageView.builder(
                    controller: _pageController,
                    // Feuilletage de droite à gauche.
                    reverse: true,
                    itemCount: AppConfig.mushafPageCount,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) {
                      final pageNumber = index + 1;
                      return RepaintBoundary(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          child: MushafPageCanvas(
                            pageNumber: pageNumber,
                            layout: session.snapshot?.pages[pageNumber],
                            fontResult:
                                _fontFor(pageNumber) ??
                                const MushafFontResult(
                                  status: MushafFontStatus.missing,
                                ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              _TopChrome(
                visible: _chromeVisible,
                page: _visiblePage,
                reciterLabel: session.reciterLabel,
                onTapReciter: _openReciterSelector,
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 14,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: IgnorePointer(
                        ignoring: !_chromeVisible,
                        child: AnimatedOpacity(
                          opacity: _chromeVisible ? 1 : 0,
                          duration: MushafTheme.chromeFadeDuration,
                          child: AudioCapsule(
                            controller: session.audio,
                            reciterLabel: session.reciterLabel,
                            opacity: _capsuleOpacity,
                            onInteraction: _markInteraction,
                            onSelectRange: _openRangeSelector,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        },
      ),
    );
  }
}

/// Bandeau supérieur : numéro de page et récitateur actif.
class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.visible,
    required this.page,
    required this.reciterLabel,
    required this.onTapReciter,
  });

  final bool visible;
  final int page;
  final String reciterLabel;
  final VoidCallback onTapReciter;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: MushafTheme.chromeFadeDuration,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: <Widget>[
              Text(
                'Page $page',
                style: const TextStyle(
                  color: MushafTheme.capsuleAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onTapReciter,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.record_voice_over_outlined,
                        size: 16,
                        color: MushafTheme.capsuleAccent,
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 190),
                        child: Text(
                          reciterLabel.isEmpty
                              ? 'Choisir un récitateur'
                              : reciterLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: MushafTheme.capsuleAccent,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Feuille de sélection de plage de versets.
class _RangeSheet extends StatefulWidget {
  const _RangeSheet({required this.verseKeys});

  final List<String> verseKeys;

  @override
  State<_RangeSheet> createState() => _RangeSheetState();
}

class _RangeSheetState extends State<_RangeSheet> {
  late String _from;
  late String _to;

  @override
  void initState() {
    super.initState();
    _from = widget.verseKeys.first;
    _to = widget.verseKeys.last;
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        widget.verseKeys.indexOf(_from) <= widget.verseKeys.indexOf(_to);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Plage de versets',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: MushafTheme.ink,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'La répétition s\'appliquera uniquement à cette plage.',
              style: TextStyle(fontSize: 12, color: MushafTheme.capsuleAccent),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: _VerseDropdown(
                    label: 'Du verset',
                    value: _from,
                    items: widget.verseKeys,
                    onChanged: (value) => setState(() => _from = value),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _VerseDropdown(
                    label: 'Au verset',
                    value: _to,
                    items: widget.verseKeys,
                    onChanged: (value) => setState(() => _to = value),
                  ),
                ),
              ],
            ),
            if (!valid)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'La fin de plage précède son début.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB3261E)),
                ),
              ),
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop((from: null, to: null)),
                  child: const Text('Page entière'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: valid
                      ? () => Navigator.of(context).pop((from: _from, to: _to))
                      : null,
                  child: const Text('Appliquer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VerseDropdown extends StatelessWidget {
  const _VerseDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          items: items
              .map(
                (key) => DropdownMenuItem<String>(value: key, child: Text(key)),
              )
              .toList(growable: false),
          onChanged: (selected) {
            if (selected != null) onChanged(selected);
          },
        ),
      ),
    );
  }
}

/// Feuille de choix du récitateur.
class _ReciterSheet extends StatelessWidget {
  const _ReciterSheet({required this.resolutions, required this.selected});

  final List<ReciterResolution> resolutions;
  final ReciterResolution? selected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              'Récitateur',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: MushafTheme.ink,
              ),
            ),
          ),
          for (final resolution in resolutions)
            ListTile(
              enabled: resolution.isResolved,
              selected: resolution.recitation?.id == selected?.recitation?.id,
              title: Text(resolution.preference.displayName),
              subtitle: Text(
                resolution.isResolved
                    ? '${resolution.recitation!.displayName} \u00b7 '
                          'identifiant ${resolution.recitation!.id}'
                    : 'Indisponible dans le catalogue Content API',
                style: const TextStyle(fontSize: 11.5),
              ),
              trailing: resolution.isResolved
                  ? null
                  : const Icon(Icons.block, size: 18),
              onTap: resolution.isResolved
                  ? () => Navigator.of(context).pop(resolution)
                  : null,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Écran d'échec au démarrage, avec la cause réelle.
class _FailureView extends StatelessWidget {
  const _FailureView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: MushafTheme.capsuleAccent,
            ),
            const SizedBox(height: 14),
            const Text(
              'Connexion à la Quran Foundation impossible',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: MushafTheme.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: MushafTheme.capsuleAccent,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      ),
    );
  }
}
