import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soumaya/config/soumaya_settings.dart';

void main() {
  group('validation de l\'adresse du proxy', () {
    test('une adresse https distante est acceptée', () {
      expect(validerProxyBaseUrl('https://proxy.exemple.fr'), isNull);
      expect(validerProxyBaseUrl('https://proxy.exemple.fr/'), isNull);
      expect(validerProxyBaseUrl('  https://proxy.exemple.fr  '), isNull);
      expect(validerProxyBaseUrl('https://proxy.exemple.fr:8443'), isNull);
    });

    test('le HTTP en clair est accepté sur le réseau local', () {
      // Le cas du développement : le proxy tourne sur la machine voisine.
      for (final adresse in <String>[
        'http://localhost:8787',
        'http://127.0.0.1:8787',
        'http://192.168.1.10:8787',
        'http://10.0.0.5:8787',
        'http://172.16.0.1:8787',
        'http://172.31.255.254:8787',
        'http://169.254.1.1:8787',
        'http://mac-mini.local:8787',
      ]) {
        expect(
          validerProxyBaseUrl(adresse),
          isNull,
          reason: '$adresse devrait être acceptée : le trafic reste local',
        );
      }
    });

    test('le HTTP en clair est refusé vers un hôte distant', () {
      // Le cas dangereux : le proxy délivre des jetons d'accès, lisibles par
      // quiconque est sur le chemin. Le refus doit NOMMER la cause.
      for (final adresse in <String>[
        'http://proxy.exemple.fr',
        'http://example.com:8787',
        'http://8.8.8.8:8787',
      ]) {
        final erreur = validerProxyBaseUrl(adresse);
        expect(erreur, isNotNull, reason: '$adresse devrait être refusée');
        expect(erreur, contains('https://'));
      }
    });

    test(
      'les adresses privées se reconnaissent à leurs bornes, pas à un préfixe',
      () {
        // Témoin : une règle qui dirait « tout 172. est privé » accepterait
        // 172.32, qui est public. 172.16.0.0/12 s'arrête à 172.31.
        expect(validerProxyBaseUrl('http://172.32.0.1:8787'), isNotNull);
        expect(validerProxyBaseUrl('http://172.15.0.1:8787'), isNotNull);
        expect(hoteLocal('172.31.0.1'), isTrue);
        expect(hoteLocal('172.32.0.1'), isFalse);
        // Et un préfixe ne doit pas être confondu avec un nombre plus long.
        expect(hoteLocal('100.64.0.1'), isFalse);
        expect(hoteLocal('192.1680.1.1'), isFalse);
      },
    );

    test('les adresses inexploitables sont refusées', () {
      expect(validerProxyBaseUrl(''), isNotNull);
      expect(validerProxyBaseUrl('   '), isNotNull);
      expect(validerProxyBaseUrl('proxy.exemple.fr'), isNotNull);
      expect(validerProxyBaseUrl('ftp://proxy.exemple.fr'), isNotNull);
      expect(validerProxyBaseUrl('https://'), isNotNull);
      expect(validerProxyBaseUrl('https://proxy.exemple.fr/a b'), isNotNull);
    });
  });

  group('normalisation', () {
    test('les barres obliques finales sont retirées', () {
      // Sans cela, l'application demanderait `https://proxy.fr//qf/token`, que
      // certains serveurs refusent — sans nommer la cause.
      expect(normaliserProxyBaseUrl('https://proxy.fr'), 'https://proxy.fr');
      expect(normaliserProxyBaseUrl('https://proxy.fr/'), 'https://proxy.fr');
      expect(normaliserProxyBaseUrl('https://proxy.fr///'), 'https://proxy.fr');
      expect(
        normaliserProxyBaseUrl('  https://proxy.fr/  '),
        'https://proxy.fr',
      );
      expect(
        normaliserProxyBaseUrl('https://proxy.fr/sous-chemin/'),
        'https://proxy.fr/sous-chemin',
      );
    });
  });

  group('validation de l\'identifiant client', () {
    test('un identifiant non vide sans espace est accepté', () {
      expect(validerClientId('abc-123'), isNull);
      expect(validerClientId('  abc-123  '), isNull);
    });

    test('un identifiant vide ou espacé est refusé', () {
      expect(validerClientId(''), isNotNull);
      expect(validerClientId('   '), isNotNull);
      expect(validerClientId('deux mots'), isNotNull);
    });
  });

  group('SoumayaSettings', () {
    test('isConfigured exige les deux valeurs', () {
      const complet = SoumayaSettings(
        proxyBaseUrl: 'https://proxy.fr',
        clientId: 'abc',
      );
      expect(complet.isConfigured, isTrue);

      expect(
        complet.copyWith(proxyBaseUrl: '').isConfigured,
        isFalse,
        reason: 'une adresse absente ne se répare pas en réessayant',
      );
      expect(complet.copyWith(clientId: '').isConfigured, isFalse);
    });

    test('copyWith ne change que le champ nommé', () {
      const origine = SoumayaSettings(
        proxyBaseUrl: 'https://a.fr',
        clientId: 'un',
      );
      final modifie = origine.copyWith(clientId: 'deux');
      expect(modifie.proxyBaseUrl, 'https://a.fr');
      expect(modifie.clientId, 'deux');
      expect(modifie, isNot(origine));
    });
  });

  group('persistance', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    const store = SoumayaSettingsStore();

    test(
      'sans préférence enregistrée, les valeurs compilées s\'appliquent',
      () async {
        final reglages = await store.load();
        // Témoin : sans lui, un magasin qui renverrait des valeurs inventées
        // passerait pour correct.
        expect(reglages, SoumayaSettings.defaults);
      },
    );

    test('une préférence vide équivaut à une préférence absente', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SoumayaSettingsStore.cleProxy: '',
        SoumayaSettingsStore.cleClient: '',
      });
      expect(await store.load(), SoumayaSettings.defaults);
    });

    test('ce qui est enregistré se relit', () async {
      await store.save(
        const SoumayaSettings(
          proxyBaseUrl: 'https://proxy.exemple.fr/',
          clientId: ' client-42 ',
        ),
      );

      final relu = await store.load();
      // L'adresse est normalisée à l'écriture, l'identifiant rogné : c'est ce
      // qui garantit que le chemin demandé est bien `/qf/token`.
      expect(relu.proxyBaseUrl, 'https://proxy.exemple.fr');
      expect(relu.clientId, 'client-42');
      expect(relu.isConfigured, isTrue);
    });

    test('une configuration invalide n\'est jamais écrite', () async {
      await expectLater(
        store.save(
          const SoumayaSettings(
            proxyBaseUrl: 'http://distant.fr',
            clientId: 'a',
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        store.save(
          const SoumayaSettings(proxyBaseUrl: 'https://a.fr', clientId: ''),
        ),
        throwsArgumentError,
      );

      // Et surtout : rien n'a été persisté au passage.
      expect(await store.load(), SoumayaSettings.defaults);
    });

    test('effacer rend la main aux valeurs compilées', () async {
      await store.save(
        const SoumayaSettings(proxyBaseUrl: 'https://a.fr', clientId: 'a'),
      );
      expect((await store.load()).proxyBaseUrl, 'https://a.fr');

      await store.clear();
      expect(await store.load(), SoumayaSettings.defaults);
    });
  });
}
