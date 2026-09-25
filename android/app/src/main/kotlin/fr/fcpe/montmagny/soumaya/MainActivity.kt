package fr.fcpe.montmagny.soumaya

import com.ryanheise.audioservice.AudioServiceActivity

/**
 * audio_service exige que l'activité principale hérite de AudioServiceActivity
 * (ou AudioServiceFragmentActivity) pour que le service de lecture partage le
 * même moteur Flutter. Sans cela, la notification et les commandes de l'écran
 * verrouillé ne sont pas reliées à l'instance du lecteur.
 */
class MainActivity : AudioServiceActivity()
