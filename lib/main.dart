import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app/soumaya_session.dart';
import 'audio/audio_controller.dart';
import 'config/credits.dart';
import 'config/soumaya_settings.dart';
import 'data/qf_token_provider.dart';
import 'data/quran_api_service.dart';
import 'ui/mushaf_page_view.dart';
import 'ui/mushaf_theme.dart';
import 'ui/setup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Crédit des polices : les conditions de la Quran Foundation l'exigent pour
  // autoriser la mise en cache. Enregistré avant `runApp` pour qu'il soit dans
  // le registre dès le premier affichage d'une page de licences.
  enregistrerCredits();

  // Les réglages sont lus **avant** `runApp` : l'écran affiché au démarrage en
  // dépend. Une préférence absente retombe sur les valeurs compilées, si bien
  // qu'un binaire construit avec la variable de dépôt démarre configuré et ne
  // passe jamais par l'écran de configuration.
  const store = SoumayaSettingsStore();
  final settings = await store.load();

  runApp(SoumayaApp(settings: settings, store: store));
}

class SoumayaApp extends StatefulWidget {
  const SoumayaApp({
    super.key,
    required this.settings,
    this.store = const SoumayaSettingsStore(),
  });

  final SoumayaSettings settings;
  final SoumayaSettingsStore store;

  @override
  State<SoumayaApp> createState() => _SoumayaAppState();
}

class _SoumayaAppState extends State<SoumayaApp> {
  late SoumayaSettings _settings;

  /// Créé une seule fois par processus : `AudioService.init` installe le côté
  /// plateforme, et le refaire en repartirait de zéro au milieu d'une écoute.
  SoumayaAudioHandler? _handler;

  SoumayaSession? _session;

  bool _demarrage = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    if (_settings.isConfigured) {
      unawaited(_demarrer(_settings));
    }
  }

  /// Construit (ou reconstruit) la session avec [reglages].
  ///
  /// Appelée au démarrage et après un enregistrement de configuration. La
  /// session précédente est libérée, mais **le gestionnaire audio est
  /// conservé** : il porte la notification et les commandes de l'écran
  /// verrouillé, et le recréer couperait une lecture en cours.
  Future<void> _demarrer(SoumayaSettings reglages) async {
    setState(() {
      _demarrage = true;
      _erreur = null;
    });

    try {
      _handler ??= await AudioService.init(
        builder: SoumayaAudioHandler.new,
        config: AudioServiceConfig(
          androidNotificationChannelId: 'fr.fcpe.montmagny.soumaya.audio',
          androidNotificationChannelName: 'Récitation coranique',
          androidNotificationOngoing: true,
          // Conserver le service au premier plan pendant une pause évite
          // `ForegroundServiceStartNotAllowedException` sur Android 12+
          // lorsqu'on reprend la lecture depuis l'arrière-plan.
          androidStopForegroundOnPause: false,
        ),
      );

      await _configureSystemAudioSession();

      final api = QuranApiService(
        tokenSource: ProxyTokenSource(
          client: http.Client(),
          proxyBaseUrl: reglages.proxyBaseUrl,
        ),
        clientId: reglages.clientId,
      );

      final session = SoumayaSession(api, _handler!);
      final ancienne = _session;

      if (!mounted) {
        session.dispose();
        return;
      }
      setState(() {
        _settings = reglages;
        _session = session;
        _demarrage = false;
      });

      ancienne?.dispose();
      unawaited(session.initialize());
    } on Object catch (erreur) {
      if (!mounted) return;
      setState(() {
        _demarrage = false;
        _erreur = erreur.toString();
      });
    }
  }

  Future<void> _enregistrer(SoumayaSettings reglages) async {
    await widget.store.save(reglages);
    await _demarrer(reglages);
  }

  /// Le contexte de `_SoumayaAppState` est **au-dessus** du `MaterialApp` : il
  /// n'a donc aucun `Navigator` pour ancêtre, et `Navigator.of(context)` y
  /// échouerait. D'où cette clé, posée sur le `MaterialApp` lui-même.
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  void _ouvrirReglages() {
    _navigator.currentState?.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SetupScreen(
          initial: _settings,
          onSaved: (reglages) async {
            await _enregistrer(reglages);
            _navigator.currentState?.pop();
          },
          onSkip: () => _navigator.currentState?.pop(),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soumaya',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: MushafTheme.capsuleAccent,
          surface: MushafTheme.paper,
        ),
        useMaterial3: true,
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    final session = _session;

    if (session != null) {
      return MushafPageView(session: session, onOpenSettings: _ouvrirReglages);
    }

    if (_demarrage) {
      return const Scaffold(
        backgroundColor: MushafTheme.scaffold,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_erreur != null) {
      return Scaffold(
        backgroundColor: MushafTheme.scaffold,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Text(
                  'Démarrage impossible',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: MushafTheme.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _erreur!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MushafTheme.capsuleAccent,
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => unawaited(_demarrer(_settings)),
                  child: const Text('Réessayer'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SetupScreen(initial: _settings, onSaved: _enregistrer);
  }
}

/// Déclare une session audio de type « parole ».
///
/// La récitation est du texte récité, pas de la musique : ce type de session
/// donne la bonne gestion des interruptions (appel entrant, autre application)
/// et autorise la lecture en arrière-plan sur iOS.
Future<void> _configureSystemAudioSession() async {
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.speech());
}
