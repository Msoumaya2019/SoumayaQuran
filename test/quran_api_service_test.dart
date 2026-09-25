import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:soumaya/data/qf_token_provider.dart';
import 'package:soumaya/data/quran_api_exception.dart';
import 'package:soumaya/data/quran_api_service.dart';

import 'support/mushaf_fixtures.dart';

class _FakeTokenSource implements QfTokenSource {
  int calls = 0;
  int invalidations = 0;

  @override
  Future<String> accessToken() async {
    calls++;
    return 'jeton-test';
  }

  @override
  void invalidate() => invalidations++;

  @override
  void dispose() {}
}

/// Réponse audio minimale, au format documenté.
String _audioResponse(
  List<Map<String, String>> files, {
  int? nextPage,
  int currentPage = 1,
}) => jsonEncode(<String, dynamic>{
  'audio_files': files,
  'pagination': <String, dynamic>{
    'per_page': 50,
    'current_page': currentPage,
    'next_page': nextPage,
    'total_pages': nextPage ?? currentPage,
    'total_records': files.length,
  },
});

QuranApiService _service(MockClient client, _FakeTokenSource tokens) =>
    QuranApiService(
      tokenSource: tokens,
      client: client,
      baseUrl: 'https://exemple.test/content/api/v4',
    );

void main() {
  group('requête audio par page', () {
    test(
      'vise le bon chemin, avec les en-têtes et per_page au maximum',
      () async {
        final requests = <http.Request>[];
        final tokens = _FakeTokenSource();

        final service = _service(
          MockClient((request) async {
            requests.add(request);
            return http.Response(
              _audioResponse(<Map<String, String>>[
                <String, String>{'verse_key': '1:1', 'url': 'a/mp3/001001.mp3'},
              ]),
              200,
            );
          }),
          tokens,
        );

        final files = await service.fetchPageAudioFiles(
          recitationId: 7,
          pageNumber: 604,
        );

        expect(requests, hasLength(1));
        final request = requests.single;
        expect(request.url.path, '/content/api/v4/recitations/7/by_page/604');
        expect(request.url.queryParameters['per_page'], '50');
        expect(request.url.queryParameters['page'], '1');
        expect(request.url.queryParameters['fields'], contains('verse_key'));
        expect(request.headers['x-auth-token'], 'jeton-test');
        expect(request.headers.containsKey('x-client-id'), isTrue);
        expect(tokens.calls, 1);

        // L'API renvoie tantôt une URL absolue, tantôt un chemin relatif.
        expect(
          files.single.url,
          'https://verses.quran.foundation/a/mp3/001001.mp3',
        );
      },
    );

    test('parcourt la pagination jusqu\'à épuisement', () async {
      var call = 0;
      final requestedPages = <String?>[];

      final service = _service(
        MockClient((request) async {
          requestedPages.add(request.url.queryParameters['page']);
          call++;
          if (call == 1) {
            return http.Response(
              _audioResponse(<Map<String, String>>[
                <String, String>{'verse_key': '2:1', 'url': 'x/002001.mp3'},
                <String, String>{'verse_key': '2:2', 'url': 'x/002002.mp3'},
              ], nextPage: 2),
              200,
            );
          }
          return http.Response(
            _audioResponse(<Map<String, String>>[
              <String, String>{'verse_key': '2:3', 'url': 'x/002003.mp3'},
            ], currentPage: 2),
            200,
          );
        }),
        _FakeTokenSource(),
      );

      final files = await service.fetchPageAudioFiles(
        recitationId: 7,
        pageNumber: 2,
      );

      expect(requestedPages, <String>['1', '2']);
      expect(files.map((f) => f.verseKey).toList(), <String>[
        '2:1',
        '2:2',
        '2:3',
      ]);
    });

    test('conserve une URL déjà absolue', () async {
      final service = _service(
        MockClient((request) async {
          return http.Response(
            _audioResponse(<Map<String, String>>[
              <String, String>{
                'verse_key': '1:1',
                'url': 'https://verses.quran.foundation/a/001001.mp3',
              },
            ]),
            200,
          );
        }),
        _FakeTokenSource(),
      );

      final files = await service.fetchPageAudioFiles(
        recitationId: 7,
        pageNumber: 1,
      );
      expect(files.single.url, 'https://verses.quran.foundation/a/001001.mp3');
    });

    test('trie les fichiers dans l\'ordre du Mushaf', () async {
      final service = _service(
        MockClient((request) async {
          return http.Response(
            _audioResponse(<Map<String, String>>[
              <String, String>{'verse_key': '2:10', 'url': 'x/002010.mp3'},
              <String, String>{'verse_key': '2:2', 'url': 'x/002002.mp3'},
              <String, String>{'verse_key': '2:3', 'url': 'x/002003.mp3'},
            ]),
            200,
          );
        }),
        _FakeTokenSource(),
      );

      final files = await service.fetchPageAudioFiles(
        recitationId: 7,
        pageNumber: 2,
      );
      expect(files.map((f) => f.verseKey).toList(), <String>[
        '2:2',
        '2:3',
        '2:10',
      ]);
    });

    test(
      'refuse un numéro de page hors bornes sans appeler le réseau',
      () async {
        var called = false;
        final service = _service(
          MockClient((request) async {
            called = true;
            return http.Response('{}', 200);
          }),
          _FakeTokenSource(),
        );

        await expectLater(
          service.fetchPageAudioFiles(recitationId: 7, pageNumber: 605),
          throwsA(
            isA<QuranApiException>().having(
              (e) => e.type,
              'type',
              'invalid_argument',
            ),
          ),
        );
        await expectLater(
          service.fetchPageAudioFiles(recitationId: 7, pageNumber: 0),
          throwsA(isA<QuranApiException>()),
        );
        expect(called, isFalse);
      },
    );
  });

  group('plage de versets', () {
    test('ne demande que les pages réellement concernées', () async {
      final paths = <String>[];

      final service = _service(
        MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(
            _audioResponse(<Map<String, String>>[
              <String, String>{'verse_key': '1:1', 'url': 'x/001001.mp3'},
              <String, String>{'verse_key': '1:2', 'url': 'x/001002.mp3'},
              <String, String>{'verse_key': '1:3', 'url': 'x/001003.mp3'},
            ]),
            200,
          );
        }),
        _FakeTokenSource(),
      );

      final files = await service.fetchVerseRangeAudioFiles(
        recitationId: 7,
        fromVerseKey: '1:1',
        toVerseKey: '1:2',
        index: buildIndex(),
      );

      expect(paths, hasLength(1));
      expect(paths.single, contains('/by_page/1'));
      // Le verset 1:3 appartient à la page mais pas à la plage demandée.
      expect(files.map((f) => f.verseKey).toList(), <String>['1:1', '1:2']);
    });

    test('couvre une plage à cheval sur deux pages', () async {
      final paths = <String>[];

      // Dans le jeu de test, la page 2 porte 1:4..1:7 et la page 3 porte
      // 2:1..2:3.
      final service = _service(
        MockClient((request) async {
          paths.add(request.url.path);
          final isPageTwo = request.url.path.endsWith('/2');
          return http.Response(
            _audioResponse(<Map<String, String>>[
              if (isPageTwo) ...<Map<String, String>>[
                <String, String>{'verse_key': '1:4', 'url': 'x/001004.mp3'},
                <String, String>{'verse_key': '1:6', 'url': 'x/001006.mp3'},
                <String, String>{'verse_key': '1:7', 'url': 'x/001007.mp3'},
              ] else ...<Map<String, String>>[
                <String, String>{'verse_key': '2:1', 'url': 'x/002001.mp3'},
                <String, String>{'verse_key': '2:2', 'url': 'x/002002.mp3'},
                <String, String>{'verse_key': '2:3', 'url': 'x/002003.mp3'},
              ],
            ]),
            200,
          );
        }),
        _FakeTokenSource(),
      );

      final files = await service.fetchVerseRangeAudioFiles(
        recitationId: 7,
        fromVerseKey: '1:6',
        toVerseKey: '2:2',
        index: buildIndex(),
      );

      expect(paths, hasLength(2));
      expect(paths[0], endsWith('/by_page/2'));
      expect(paths[1], endsWith('/by_page/3'));
      // 1:4 et 2:3 appartiennent aux pages mais pas à la plage demandée.
      expect(files.map((f) => f.verseKey).toList(), <String>[
        '1:6',
        '1:7',
        '2:1',
        '2:2',
      ]);
    });

    test('refuse une plage inversée', () async {
      final service = _service(
        MockClient((request) async => http.Response('{}', 200)),
        _FakeTokenSource(),
      );

      await expectLater(
        service.fetchVerseRangeAudioFiles(
          recitationId: 7,
          fromVerseKey: '2:1',
          toVerseKey: '1:1',
          index: buildIndex(),
        ),
        throwsA(
          isA<QuranApiException>().having(
            (e) => e.type,
            'type',
            'invalid_argument',
          ),
        ),
      );
    });
  });

  group('gestion des erreurs et des jetons', () {
    test('réessaie après un 429 en respectant Retry-After', () async {
      var attempt = 0;
      final service = _service(
        MockClient((request) async {
          attempt++;
          if (attempt == 1) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'message': 'Trop de requêtes',
                'type': 'rate_limit_exceeded',
                'success': false,
              }),
              429,
              headers: <String, String>{'retry-after': '0'},
            );
          }
          return http.Response(
            _audioResponse(<Map<String, String>>[
              <String, String>{'verse_key': '1:1', 'url': 'x/001001.mp3'},
            ]),
            200,
          );
        }),
        _FakeTokenSource(),
      );

      final files = await service.fetchPageAudioFiles(
        recitationId: 7,
        pageNumber: 1,
      );
      expect(attempt, 2);
      expect(files.single.verseKey, '1:1');
    });

    test(
      'abandonne après trois tentatives sur une erreur persistante',
      () async {
        var attempt = 0;
        final service = _service(
          MockClient((request) async {
            attempt++;
            return http.Response(
              jsonEncode(<String, dynamic>{
                'message': 'Indisponible',
                'type': 'service_unavailable',
                'success': false,
              }),
              503,
              headers: <String, String>{'retry-after': '0'},
            );
          }),
          _FakeTokenSource(),
        );

        await expectLater(
          service.fetchPageAudioFiles(recitationId: 7, pageNumber: 1),
          throwsA(
            isA<QuranApiException>()
                .having((e) => e.statusCode, 'statusCode', 503)
                .having((e) => e.type, 'type', 'service_unavailable'),
          ),
        );
        expect(attempt, 3);
      },
    );

    test('invalide le jeton et réessaie une fois sur un 401', () async {
      final tokens = _FakeTokenSource();
      var attempt = 0;

      final service = _service(
        MockClient((request) async {
          attempt++;
          if (attempt == 1) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'message': 'Jeton expiré',
                'type': 'unauthorized',
                'success': false,
              }),
              401,
            );
          }
          return http.Response(
            _audioResponse(<Map<String, String>>[
              <String, String>{'verse_key': '1:1', 'url': 'x/001001.mp3'},
            ]),
            200,
          );
        }),
        tokens,
      );

      final files = await service.fetchPageAudioFiles(
        recitationId: 7,
        pageNumber: 1,
      );

      expect(tokens.invalidations, 1);
      expect(tokens.calls, 2);
      expect(files.single.verseKey, '1:1');
    });

    test('remonte le type d\'erreur renvoyé par l\'API', () async {
      final service = _service(
        MockClient((request) async {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'message': 'Scope content manquant',
              'type': 'insufficient_scope',
              'success': false,
            }),
            403,
          );
        }),
        _FakeTokenSource(),
      );

      await expectLater(
        service.fetchPageAudioFiles(recitationId: 7, pageNumber: 1),
        throwsA(
          isA<QuranApiException>()
              .having((e) => e.type, 'type', 'insufficient_scope')
              .having((e) => e.isAuthenticationFailure, 'auth', isTrue),
        ),
      );
    });
  });

  group('structure du Mushaf', () {
    test('lit le nombre de versets par sourate', () async {
      final service = _service(
        MockClient((request) async {
          expect(request.url.path, '/content/api/v4/chapters');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'chapters': <Map<String, dynamic>>[
                <String, dynamic>{'id': 1, 'verses_count': 7},
                <String, dynamic>{'id': 2, 'verses_count': 286},
              ],
            }),
            200,
          );
        }),
        _FakeTokenSource(),
      );

      final counts = await service.fetchChapterVerseCounts();
      expect(counts, <int, int>{1: 7, 2: 286});
    });

    test('lit l\'instantané du Mushaf', () async {
      final service = _service(
        MockClient((request) async {
          expect(
            request.url.path,
            '/content/api/v4/resources/snapshots/mushafs/1',
          );
          return http.Response(jsonEncode(buildSnapshotJson()), 200);
        }),
        _FakeTokenSource(),
      );

      final snapshot = await service.fetchMushafSnapshot();
      expect(snapshot.defaultFontName, 'v2');
      expect(snapshot.linesPerPage, 15);
      expect(snapshot.pages.length, 3);
    });
  });
}
