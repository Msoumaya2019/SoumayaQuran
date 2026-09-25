import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app/soumaya_session.dart';
import 'audio/audio_controller.dart';
import 'data/qf_token_provider.dart';
import 'data/quran_api_service.dart';
import 'ui/mushaf_page_view.dart';
import 'ui/mushaf_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final session = await _bootstrap();

  runApp(SoumayaApp(session: session));
}

/// Prépare la session : service audio d'arrière-plan, session système, client
/// API.
Future<SoumayaSession> _bootstrap() async {
  // Le gestionnaire audio est créé par le service d'arrière-plan : c'est lui
  // qui porte la notification Android et les commandes de l'écran verrouillé.
  final handler = await AudioService.init(
    builder: SoumayaAudioHandler.new,
    config: AudioServiceConfig(
      androidNotificationChannelId: 'fr.fcpe.montmagny.soumaya.audio',
      androidNotificationChannelName: 'Récitation coranique',
      androidNotificationOngoing: true,
      // Conserver le service au premier plan pendant une pause évite
      // `ForegroundServiceStartNotAllowedException` sur Android 12+ lorsqu'on
      // reprend la lecture depuis l'arrière-plan.
      androidStopForegroundOnPause: false,
    ),
  );

  await _configureSystemAudioSession();

  final api = QuranApiService(
    tokenSource: ProxyTokenSource(client: http.Client()),
  );

  final session = SoumayaSession(api, handler);
  unawaited(session.initialize());
  return session;
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

class SoumayaApp extends StatelessWidget {
  const SoumayaApp({super.key, required this.session});

  final SoumayaSession session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soumaya',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: MushafTheme.capsuleAccent,
          surface: MushafTheme.paper,
        ),
        useMaterial3: true,
      ),
      home: MushafPageView(session: session),
    );
  }
}
