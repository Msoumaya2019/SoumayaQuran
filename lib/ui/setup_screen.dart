import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/soumaya_settings.dart';
import 'mushaf_theme.dart';

/// Écran de configuration : l'adresse du proxy de jetons et l'identifiant
/// client.
///
/// ## Pourquoi un écran, et pas une recompilation
///
/// Ces deux valeurs étaient des constantes de compilation. Un binaire compilé
/// sans elles ne pouvait donc **jamais** fonctionner, et celui qui installe
/// l'application n'a pas de chaîne de compilation sous la main. Les saisir ici
/// est ce qui rend une version publiée réellement utilisable.
///
/// ## Ce que l'écran ne demande pas
///
/// Le `client_secret`. Il ne doit jamais entrer dans l'application : il reste
/// sur le proxy. L'écran le dit explicitement, parce que c'est la question que
/// se posera quiconque a vu la console développeur, où les deux valeurs sont
/// affichées côte à côte.
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.initial,
    required this.onSaved,
    this.client,
    this.onSkip,
  });

  final SoumayaSettings initial;

  /// Appelé après un enregistrement réussi.
  final Future<void> Function(SoumayaSettings) onSaved;

  /// Client HTTP, injectable pour que l'essai de connexion soit éprouvable.
  final http.Client? client;

  /// Appelé si l'utilisateur choisit de continuer sans configurer.
  final VoidCallback? onSkip;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _proxy;
  late final TextEditingController _clientId;
  late final http.Client _http;

  String? _erreurProxy;
  String? _erreurClient;
  bool _enregistrement = false;

  /// Résultat du dernier essai de connexion, ou `null` si aucun n'a eu lieu.
  ({bool ok, String message})? _essai;

  bool _essaiEnCours = false;

  @override
  void initState() {
    super.initState();
    _proxy = TextEditingController(text: widget.initial.proxyBaseUrl);
    _clientId = TextEditingController(text: widget.initial.clientId);
    _http = widget.client ?? http.Client();
  }

  @override
  void dispose() {
    _proxy.dispose();
    _clientId.dispose();
    if (widget.client == null) _http.close();
    super.dispose();
  }

  SoumayaSettings get _saisie => SoumayaSettings(
    proxyBaseUrl: normaliserProxyBaseUrl(_proxy.text),
    clientId: _clientId.text.trim(),
  );

  /// Valide les deux champs et pose les messages d'erreur.
  bool _valider() {
    final erreurProxy = validerProxyBaseUrl(_proxy.text);
    final erreurClient = validerClientId(_clientId.text);
    setState(() {
      _erreurProxy = erreurProxy;
      _erreurClient = erreurClient;
    });
    return erreurProxy == null && erreurClient == null;
  }

  /// Interroge `GET {proxy}/qf/token` et rapporte ce qui s'est réellement passé.
  ///
  /// L'essai porte sur le proxy et non sur l'API : c'est le seul maillon dont
  /// la configuration dépend. Un jeton reçu prouve la chaîne complète —
  /// l'application, le proxy, et le `client_secret` que le proxy détient.
  Future<void> _tester() async {
    if (!_valider()) return;

    setState(() {
      _essaiEnCours = true;
      _essai = null;
    });

    final base = normaliserProxyBaseUrl(_proxy.text);
    final resultat = await _interroger(base);

    if (!mounted) return;
    setState(() {
      _essaiEnCours = false;
      _essai = resultat;
    });
  }

  Future<({bool ok, String message})> _interroger(String base) async {
    final uri = Uri.tryParse('$base/qf/token');
    if (uri == null) {
      return (ok: false, message: 'Adresse illisible.');
    }

    try {
      final reponse = await _http
          .get(
            uri,
            headers: const <String, String>{'accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 15));

      if (reponse.statusCode != 200) {
        return (
          ok: false,
          message:
              'Le proxy a répondu ${reponse.statusCode}. '
              'Vérifiez qu\'il tourne et que QF_CLIENT_ID et QF_CLIENT_SECRET '
              'y sont renseignés.\n${_extrait(reponse.body)}',
        );
      }

      final decode = jsonDecode(reponse.body);
      if (decode is! Map<String, dynamic> ||
          decode['access_token'] is! String) {
        return (
          ok: false,
          message:
              'Le proxy a répondu 200, mais sans access_token. '
              'L\'adresse pointe-t-elle bien vers le proxy de Soumaya ?',
        );
      }

      final secondes = decode['expires_in'];
      return (
        ok: true,
        message:
            'Jeton reçu'
            '${secondes is int ? ' (valable $secondes s)' : ''}. '
            'La chaîne application → proxy → Quran Foundation fonctionne.',
      );
    } on TimeoutException {
      return (
        ok: false,
        message:
            'Aucune réponse en 15 s. Le téléphone joint-il cette adresse ? '
            'Depuis un appareil, « localhost » désigne le téléphone lui-même.',
      );
    } on Object catch (erreur) {
      return (
        ok: false,
        message:
            'Connexion impossible : $erreur\n\n'
            'Depuis un appareil, « 127.0.0.1 » désigne le téléphone, pas '
            'l\'ordinateur : utilisez son adresse sur le réseau local.',
      );
    }
  }

  /// Première ligne de la réponse, tronquée : de quoi diagnostiquer sans
  /// déverser un corps entier dans l'écran.
  static String _extrait(String corps) {
    final ligne = corps.trim().split('\n').first;
    return ligne.length <= 200 ? ligne : '${ligne.substring(0, 200)}…';
  }

  Future<void> _enregistrer() async {
    if (!_valider()) return;

    setState(() => _enregistrement = true);
    await widget.onSaved(_saisie);
    if (!mounted) return;
    setState(() => _enregistrement = false);
  }

  @override
  Widget build(BuildContext context) {
    final defautsDisponibles =
        SoumayaSettings.defaults.proxyBaseUrl.isNotEmpty ||
        SoumayaSettings.defaults.clientId.isNotEmpty;

    return Scaffold(
      backgroundColor: MushafTheme.scaffold,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
          children: <Widget>[
            const Text(
              'Configuration',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w500,
                color: MushafTheme.ink,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Soumaya a besoin d\'un proxy de jetons pour joindre la Quran '
              'Foundation. Le proxy détient le client_secret ; l\'application, '
              'elle, ne le voit jamais.',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: MushafTheme.capsuleAccent,
              ),
            ),
            const SizedBox(height: 20),

            TextField(
              controller: _proxy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Adresse du proxy',
                hintText: 'https://proxy.exemple.fr',
                errorText: _erreurProxy,
                helperText:
                    'Sans barre oblique finale. Le jeton est obtenu '
                    'sur /qf/token.',
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),

            TextField(
              controller: _clientId,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Client ID',
                hintText: 'affiché dans la console développeur',
                errorText: _erreurClient,
                helperText:
                    'L\'identifiant public, pas le secret. Le secret '
                    'reste sur le proxy.',
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),

            if (_essai != null) ...<Widget>[
              const SizedBox(height: 18),
              _EssaiResultat(essai: _essai!),
            ],

            const SizedBox(height: 22),
            Row(
              children: <Widget>[
                OutlinedButton(
                  onPressed: _essaiEnCours ? null : _tester,
                  child: _essaiEnCours
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Tester la connexion'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _enregistrement ? null : _enregistrer,
                  child: const Text('Enregistrer'),
                ),
              ],
            ),

            const SizedBox(height: 26),
            const Divider(),
            const SizedBox(height: 10),
            const Text(
              'Où trouver ces valeurs',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: MushafTheme.ink,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Console développeur de la Quran Foundation. Créez une '
              'application, puis relevez le Client ID. La production se demande '
              'séparément : le bac à sable pre-live ne contient que les sourates '
              '1 et 2.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: MushafTheme.capsuleAccent,
              ),
            ),

            if (defautsDisponibles) ...<Widget>[
              const SizedBox(height: 14),
              Text(
                'Ce binaire a été compilé avec des valeurs par défaut : '
                '${SoumayaSettings.defaults.proxyBaseUrl.isEmpty ? 'aucune adresse de proxy' : SoumayaSettings.defaults.proxyBaseUrl}. '
                'Effacer les réglages enregistrés y revient.',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: MushafTheme.capsuleAccent,
                ),
              ),
            ],

            if (widget.onSkip != null) ...<Widget>[
              const SizedBox(height: 18),
              TextButton(
                onPressed: widget.onSkip,
                child: const Text('Continuer sans configurer'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bandeau de résultat de l'essai de connexion.
class _EssaiResultat extends StatelessWidget {
  const _EssaiResultat({required this.essai});

  final ({bool ok, String message}) essai;

  @override
  Widget build(BuildContext context) {
    // Deux teintes seulement, et le texte dit toujours la même chose que la
    // couleur : une pastille verte sans phrase ne dirait rien à personne.
    final fond = essai.ok ? const Color(0xFFE1F5EE) : const Color(0xFFFCEBEB);
    final bord = essai.ok ? const Color(0xFF0F6E56) : const Color(0xFFA32D2D);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: bord, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            essai.ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 18,
            color: bord,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              essai.message,
              style: TextStyle(fontSize: 12.5, height: 1.5, color: bord),
            ),
          ),
        ],
      ),
    );
  }
}
