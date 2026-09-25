package fr.fcpe.montmagny.soumaya

import com.ryanheise.audioservice.AudioServiceActivity

/**
 * audio_service impose que l'activité principale hérite de sa classe de base,
 * faute de quoi la lecture en arrière-plan est interrompue et les commandes de
 * l'écran verrouillé ne répondent plus.
 *
 * Si votre MainActivity étend déjà FlutterFragmentActivity, utilisez
 * `AudioServiceFragmentActivity` à la place.
 */
class MainActivity : AudioServiceActivity()
