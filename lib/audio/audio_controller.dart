import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../data/models/audio_file.dart';
import '../data/models/verse_key.dart';
import 'playback_plan.dart';

/// Gestionnaire audio de Soumaya : file d'attente de versets, moteur de
/// répétition, et lecture en arrière-plan.
///
/// Hérite de [BaseAudioHandler] : c'est ce qui donne la notification Android,
/// les commandes de l'écran verrouillé et le centre de contrôle iOS.
///
/// La file est reconstruite à chaque changement de portée, mais l'audio n'est
/// **pas** ré-encodé : on ne fait que réordonner des URL de versets déjà
/// connues.
class SoumayaAudioHandler extends BaseAudioHandler with SeekHandler {
  SoumayaAudioHandler({AudioPlayer? player})
    : _player = player ?? AudioPlayer() {
    _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object error, StackTrace stackTrace) {
        _reportError(error);
      },
    );

    _player.errorStream.listen((Object error) => _reportError(error));

    _player.processingStateStream.listen((ProcessingState state) {
      if (state == ProcessingState.completed) {
        unawaited(_onTrackCompleted());
      }
    });
  }

  final AudioPlayer _player;

  /// Tous les fichiers connus pour la sélection courante (typiquement la page
  /// entière), avant application d'une éventuelle plage de versets.
  List<AudioFile> _allFiles = const <AudioFile>[];

  /// Les fichiers effectivement en file, après filtrage par la plage.
  List<AudioFile> _queue = const <AudioFile>[];

  PlaybackCursor? _cursor;
  RepeatPolicy _policy = const RepeatPolicy();

  String _reciterLabel = '';
  String _pageLabel = '';

  /// Empêche un double avancement : `completed` peut être émis plusieurs fois
  /// lors des transitions de tampon.
  bool _handlingCompletion = false;

  String? _lastError;

  String? get lastError => _lastError;
  RepeatPolicy get policy => _policy;
  List<AudioFile> get queueFiles => List<AudioFile>.unmodifiable(_queue);
  String? get currentVerseKey => _cursor?.current;
  String get progressLabel => _cursor?.progressLabel ?? '';
  AudioPlayer get player => _player;

  // ---------------------------------------------------------------------------
  // Chargement
  // ---------------------------------------------------------------------------

  /// Charge une sélection de versets et démarre la lecture.
  ///
  /// [startAtVerseKey] permet d'ouvrir la page et de commencer à un verset
  /// précis plutôt qu'au premier.
  Future<void> loadSelection({
    required List<AudioFile> files,
    required String reciterLabel,
    required String pageLabel,
    RepeatPolicy policy = const RepeatPolicy(),
    String? startAtVerseKey,
    bool autoPlay = true,
  }) async {
    if (files.isEmpty) {
      throw ArgumentError.value(files, 'files', 'Aucun verset à lire.');
    }

    _allFiles = List<AudioFile>.unmodifiable(files);
    _reciterLabel = reciterLabel;
    _pageLabel = pageLabel;
    _policy = policy;
    _lastError = null;

    _rebuildQueue(startAtVerseKey: startAtVerseKey);

    queue.add(_queue.map(_mediaItemFor).toList(growable: false));
    await _playCurrent(autoPlay: autoPlay);
  }

  /// Restreint la lecture à la plage [from]..[to] (bornes incluses), ou
  /// revient à la page entière si les deux bornes sont `null`.
  ///
  /// Le verset en cours est conservé s'il appartient encore à la plage.
  Future<void> setVerseRange({
    String? from,
    String? to,
    bool autoPlay = true,
  }) async {
    if (_allFiles.isEmpty) return;

    final currentVerse = _cursor?.current;
    final filtered = _filterRange(_allFiles, from, to);

    if (filtered.isEmpty) {
      throw ArgumentError(
        'Plage vide : "$from".."$to" ne contient aucun verset de la sélection.',
      );
    }

    _queue = filtered;
    final keep =
        currentVerse != null && filtered.any((f) => f.verseKey == currentVerse)
        ? currentVerse
        : null;

    _rebuildQueue(startAtVerseKey: keep);
    queue.add(_queue.map(_mediaItemFor).toList(growable: false));
    await _playCurrent(autoPlay: autoPlay);
  }

  void _rebuildQueue({String? startAtVerseKey}) {
    _cursor = PlaybackCursor(
      verses: _queue.map((file) => file.verseKey).toList(growable: false),
      policy: _policy,
    );
    if (startAtVerseKey != null) {
      _cursor!.jumpTo(startAtVerseKey);
    }
  }

  /// Filtre une liste de fichiers sur une plage de versets.
  @visibleForTesting
  static List<AudioFile> filterRange(
    List<AudioFile> files, {
    String? from,
    String? to,
  }) => _filterRange(files, from, to);

  static List<AudioFile> _filterRange(
    List<AudioFile> files,
    String? from,
    String? to,
  ) {
    if (from == null && to == null) return files;

    final start = from == null ? null : VerseKey.tryParse(from);
    final end = to == null ? null : VerseKey.tryParse(to);

    if (from != null && start == null) {
      throw ArgumentError.value(from, 'from', 'Clé de verset illisible.');
    }
    if (to != null && end == null) {
      throw ArgumentError.value(to, 'to', 'Clé de verset illisible.');
    }
    if (start != null && end != null && end < start) {
      throw ArgumentError('La fin de plage ($end) précède son début ($start).');
    }

    return files
        .where((file) {
          final key = VerseKey.tryParse(file.verseKey);
          if (key == null) return false;
          if (start != null && key < start) return false;
          if (end != null && key > end) return false;
          return true;
        })
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Lecture
  // ---------------------------------------------------------------------------

  Future<void> _playCurrent({bool autoPlay = true}) async {
    final cursor = _cursor;
    if (cursor == null) return;

    final file = _queue[cursor.verseIndex];
    mediaItem.add(_mediaItemFor(file));
    playbackState.add(
      playbackState.value.copyWith(queueIndex: cursor.verseIndex),
    );

    try {
      await _player.setUrl(file.url);
    } on Object catch (error) {
      _reportError(error);
      return;
    }

    if (autoPlay) {
      await _player.play();
    }
  }

  Future<void> _onTrackCompleted() async {
    if (_handlingCompletion) return;
    _handlingCompletion = true;
    try {
      final cursor = _cursor;
      if (cursor == null) return;

      if (cursor.advance()) {
        await _playCurrent();
      } else {
        // Fin de la sélection : on s'arrête et on se replace au début, prêt
        // pour une nouvelle écoute.
        await _player.pause();
        await _player.seek(Duration.zero);
        cursor.reset();
        _broadcastState(_player.playbackEvent);
      }
    } finally {
      _handlingCompletion = false;
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    final cursor = _cursor;
    if (cursor == null || !cursor.hasNext) return;
    cursor.advance();
    await _playCurrent();
  }

  @override
  Future<void> skipToPrevious() async {
    final cursor = _cursor;
    if (cursor == null) return;

    // Comportement attendu d'un lecteur : un appui en cours de verset revient
    // d'abord au début du verset, un second appui passe au verset précédent.
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    if (!cursor.hasPrevious) {
      await _player.seek(Duration.zero);
      return;
    }
    cursor.retreat();
    await _playCurrent();
  }

  /// Se place sur un verset précis de la file.
  Future<void> seekToVerse(String verseKey) async {
    final cursor = _cursor;
    if (cursor == null || !cursor.jumpTo(verseKey)) return;
    await _playCurrent();
  }

  /// Change la politique de répétition sans interrompre la lecture.
  void setRepeatPolicy(RepeatPolicy value) {
    _policy = value;
    _cursor?.policy = value;
    // Le compteur de répétition du verset courant n'a plus de sens sous la
    // nouvelle politique : on repart d'une écoute propre pour ce verset.
    if (value.scope == RepeatScope.perVerse) {
      _cursor?.reset();
      final currentVerse = _cursor?.current;
      if (currentVerse != null) _cursor?.jumpTo(currentVerse);
    }
    playbackState.add(playbackState.value.copyWith());
  }

  // ---------------------------------------------------------------------------
  // Notification / écran verrouillé
  // ---------------------------------------------------------------------------

  MediaItem _mediaItemFor(AudioFile file) {
    final duration = file.duration;
    return MediaItem(
      id: file.url,
      album: _pageLabel.isEmpty ? 'Soumaya' : _pageLabel,
      title: 'Verset ${file.verseKey}',
      artist: _reciterLabel.isEmpty ? 'Soumaya' : _reciterLabel,
      duration: duration == null ? null : Duration(seconds: duration),
      extras: <String, dynamic>{'verse_key': file.verseKey},
    );
  }

  void _broadcastState(PlaybackEvent event) {
    final cursor = _cursor;
    final playing = _player.playing;

    playbackState.add(
      playbackState.value.copyWith(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const <MediaAction>{MediaAction.seek},
        androidCompactActionIndices: const <int>[0, 1, 2],
        processingState: _mapProcessingState(_player.processingState),
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: cursor?.verseIndex,
      ),
    );
  }

  static AudioProcessingState _mapProcessingState(ProcessingState state) {
    return switch (state) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
  }

  void _reportError(Object error) {
    _lastError = error.toString();
    debugPrint('[Soumaya/audio] $error');
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        errorMessage: _lastError,
        playing: false,
      ),
    );
  }

  Future<void> disposeHandler() => _player.dispose();
}

/// Façade observée par l'interface.
///
/// Le [SoumayaAudioHandler] est un singleton créé par `AudioService.init` ;
/// cette façade en expose une vue `ChangeNotifier` utilisable directement par
/// les widgets, sans leur faire manipuler des flux.
class AudioController extends ChangeNotifier {
  AudioController(this._handler) {
    _subscriptions.addAll(<StreamSubscription<dynamic>>[
      _handler.playbackState.listen((_) => notifyListeners()),
      _handler.mediaItem.listen((_) => notifyListeners()),
      _handler.queue.listen((_) => notifyListeners()),
    ]);
  }

  final SoumayaAudioHandler _handler;
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  /// Flux de position, exposé tel quel.
  ///
  /// La position avance plusieurs fois par seconde : la diffuser via
  /// `notifyListeners` reconstruirait toute la page du Mushaf à chaque tick.
  /// Les widgets qui affichent la progression s'abonnent donc directement.
  Stream<Duration> get positionStream => _handler.player.positionStream;

  PlaybackState get playbackState => _handler.playbackState.value;
  MediaItem? get mediaItem => _handler.mediaItem.value;

  bool get isPlaying => _handler.player.playing;
  bool get isBuffering =>
      _handler.player.processingState == ProcessingState.buffering ||
      _handler.player.processingState == ProcessingState.loading;

  Duration get position => _handler.player.position;
  Duration get duration => _handler.player.duration ?? Duration.zero;

  RepeatPolicy get policy => _handler.policy;
  String get progressLabel => _handler.progressLabel;
  String? get currentVerseKey => _handler.currentVerseKey;
  String? get lastError => _handler.lastError;
  List<AudioFile> get queueFiles => _handler.queueFiles;

  double get progress {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Future<void> togglePlayPause() =>
      isPlaying ? _handler.pause() : _handler.play();

  Future<void> next() => _handler.skipToNext();
  Future<void> previous() => _handler.skipToPrevious();
  Future<void> seek(Duration position) => _handler.seek(position);
  Future<void> seekToVerse(String verseKey) => _handler.seekToVerse(verseKey);

  void setPolicy(RepeatPolicy policy) {
    _handler.setRepeatPolicy(policy);
    notifyListeners();
  }

  Future<void> setRange({String? from, String? to}) async {
    await _handler.setVerseRange(from: from, to: to);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    super.dispose();
  }
}
