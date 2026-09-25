import 'dart:ui';

// Flutter exporte lui aussi un `RepeatMode` (animation de répétition) : on
// masque le sien, sans quoi le nôtre devient ambigu.
import 'package:flutter/material.dart' hide RepeatMode;

import '../audio/audio_controller.dart';
import '../audio/playback_plan.dart';
import 'mushaf_theme.dart';

/// Capsule audio flottante : récitateur, navigation verset à verset, lecture,
/// et sélecteur de répétition.
///
/// Elle est posée en superposition de la page du Mushaf et se fond dans le
/// papier grâce à un `BackdropFilter` : le flou reprend le contenu situé
/// derrière la capsule, ce qui évite l'effet de bloc opaque au milieu du texte.
class AudioCapsule extends StatelessWidget {
  const AudioCapsule({
    super.key,
    required this.controller,
    required this.reciterLabel,
    required this.opacity,
    required this.onInteraction,
    required this.onSelectRange,
  });

  final AudioController controller;

  /// Récitateur actif, tel qu'affiché dans la capsule.
  final String reciterLabel;

  /// Opacité cible : 1 au toucher, réduite après quelques secondes.
  final double opacity;

  /// Signalé à chaque interaction, pour repousser l'estompage.
  final VoidCallback onInteraction;

  /// Ouvre le sélecteur de plage de versets.
  final VoidCallback onSelectRange;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: opacity,
      duration: MushafTheme.chromeFadeDuration,
      curve: Curves.easeOut,
      child: ClipRRect(
        borderRadius: MushafTheme.capsuleRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: MushafTheme.capsuleSurface,
              borderRadius: MushafTheme.capsuleRadius,
              border: Border.all(color: MushafTheme.capsuleBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _Header(reciterLabel: reciterLabel, controller: controller),
                  const SizedBox(height: 2),
                  _ProgressBar(
                    controller: controller,
                    onInteraction: onInteraction,
                  ),
                  const SizedBox(height: 2),
                  _Controls(
                    controller: controller,
                    onInteraction: onInteraction,
                    onSelectRange: onSelectRange,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.reciterLabel, required this.controller});

  final String reciterLabel;
  final AudioController controller;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: MushafTheme.capsuleAccent,
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );

    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            reciterLabel.isEmpty ? 'Récitateur' : reciterLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          controller.currentVerseKey == null
              ? controller.progressLabel
              : '${controller.currentVerseKey} \u00b7 ${controller.progressLabel}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(fontWeight: FontWeight.w400),
        ),
      ],
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.controller, required this.onInteraction});

  final AudioController controller;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    // Abonnement local au flux de position : seule cette barre se reconstruit
    // à chaque avancée, pas la page du Mushaf située dessous.
    return StreamBuilder<Duration>(
      stream: controller.positionStream,
      builder: (context, snapshot) {
        final position = snapshot.data ?? controller.position;
        final total = controller.duration.inMilliseconds;
        final value = position.inMilliseconds.clamp(0, total).toDouble();

        return SizedBox(
          height: 18,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              activeTrackColor: MushafTheme.capsuleAccent,
              inactiveTrackColor: MushafTheme.capsuleAccent.withValues(
                alpha: 0.22,
              ),
              thumbColor: MushafTheme.capsuleAccent,
              overlayColor: MushafTheme.capsuleAccent.withValues(alpha: 0.12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: total <= 0 ? 0 : value,
              max: total <= 0 ? 1 : total.toDouble(),
              onChanged: total <= 0
                  ? null
                  : (position) {
                      onInteraction();
                      controller.seek(Duration(milliseconds: position.round()));
                    },
            ),
          ),
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
    required this.onInteraction,
    required this.onSelectRange,
  });

  final AudioController controller;
  final VoidCallback onInteraction;
  final VoidCallback onSelectRange;

  @override
  Widget build(BuildContext context) {
    final policy = controller.policy;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        _IconButton(
          icon: Icons.replay_10,
          tooltip: 'Verset précédent',
          semanticLabel: '|◀◀ Verset précédent',
          onPressed: () {
            onInteraction();
            controller.previous();
          },
        ),
        _PlayPauseButton(controller: controller, onInteraction: onInteraction),
        _IconButton(
          icon: Icons.forward_10,
          tooltip: 'Verset suivant',
          semanticLabel: '▶▶| Verset suivant',
          onPressed: () {
            onInteraction();
            controller.next();
          },
        ),
        _RepeatChip(
          policy: policy,
          onTap: () {
            onInteraction();
            // Appui court : on parcourt 1x → 2x → 3x → 5x → ∞ → 1x.
            final modes = RepeatMode.values;
            final next = modes[(modes.indexOf(policy.mode) + 1) % modes.length];
            controller.setPolicy(policy.copyWith(mode: next));
          },
          onLongPress: () {
            onInteraction();
            // Appui long : on bascule entre répétition du verset et de la plage.
            controller.setPolicy(
              policy.copyWith(
                scope: policy.scope == RepeatScope.perVerse
                    ? RepeatScope.wholeRange
                    : RepeatScope.perVerse,
              ),
            );
          },
        ),
        _IconButton(
          icon: Icons.tune,
          tooltip: 'Plage de versets',
          semanticLabel: 'Choisir une plage de versets',
          onPressed: () {
            onInteraction();
            onSelectRange();
          },
        ),
      ],
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.controller,
    required this.onInteraction,
  });

  final AudioController controller;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    final isPlaying = controller.isPlaying;

    return Semantics(
      button: true,
      label: isPlaying ? 'Pause' : 'Lecture',
      child: SizedBox(
        width: 44,
        height: 44,
        child: Material(
          color: MushafTheme.capsuleAccent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              onInteraction();
              controller.togglePlayPause();
            },
            child: controller.isBuffering
                ? const Padding(
                    padding: EdgeInsets.all(13),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
          ),
        ),
      ),
    );
  }
}

class _RepeatChip extends StatelessWidget {
  const _RepeatChip({
    required this.policy,
    required this.onTap,
    required this.onLongPress,
  });

  final RepeatPolicy policy;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final active = policy.isActive;

    return Semantics(
      button: true,
      label:
          'Répétition ${policy.mode.label}, portée ${policy.scope.label}. '
          'Appui long pour changer la portée.',
      child: Tooltip(
        message:
            'Répétition ${policy.mode.label} \u00b7 ${policy.scope.label}\n'
            'Appui court : multiplicateur \u00b7 appui long : portée',
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.repeat_rounded,
                  size: 17,
                  color: active
                      ? MushafTheme.capsuleAccent
                      : MushafTheme.capsuleInk.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 3),
                Text(
                  policy.mode.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active
                        ? MushafTheme.capsuleAccent
                        : MushafTheme.capsuleInk.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  policy.scope.label,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: MushafTheme.capsuleInk.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.semanticLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final String semanticLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 21, color: MushafTheme.capsuleInk),
          ),
        ),
      ),
    );
  }
}
