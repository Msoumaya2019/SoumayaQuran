import 'package:soumaya/data/models/mushaf_index.dart';
import 'package:soumaya/data/models/mushaf_layout.dart';
import 'package:soumaya/data/models/verse_key.dart';

/// Jeu de données réduit mais de même forme que la réponse réelle de
/// `GET /resources/snapshots/mushafs/1`.
///
/// On simule un « Coran » de deux sourates : la première de 7 versets, la
/// seconde de 5, réparties sur 3 pages.
Map<String, dynamic> buildSnapshotJson() => <String, dynamic>{
  'resource_group': 'mushafs',
  'resource_id': 1,
  'schema_version': 1,
  'records': <Map<String, dynamic>>[
    <String, dynamic>{
      'record_type': 'mushaf',
      'id': 1,
      'name': 'QCF V2',
      'pages_count': 3,
      'lines_per_page': 15,
      'default_font_name': 'v2',
    },
    <String, dynamic>{
      'record_type': 'mushaf_page',
      'id': 10,
      'page_number': 1,
      'first_verse_id': 1,
      'last_verse_id': 3,
      'verses_count': 3,
    },
    <String, dynamic>{
      'record_type': 'mushaf_page',
      'id': 11,
      'page_number': 2,
      'first_verse_id': 4,
      'last_verse_id': 7,
      'verses_count': 4,
    },
    <String, dynamic>{
      'record_type': 'mushaf_page',
      'id': 12,
      'page_number': 3,
      'first_verse_id': 8,
      'last_verse_id': 10,
      'verses_count': 3,
    },
    // Deux mots sur la ligne 1 de la page 1, volontairement donnés dans le
    // désordre : le tri par position_in_line doit les remettre en ordre.
    <String, dynamic>{
      'record_type': 'mushaf_word',
      'id': 31,
      'word_id': 2,
      'verse_id': 1,
      'text': 'glyphe-2',
      'char_type_name': 'word',
      'page_number': 1,
      'line_number': 1,
      'position_in_line': 2,
      'position_in_page': 2,
    },
    <String, dynamic>{
      'record_type': 'mushaf_word',
      'id': 30,
      'word_id': 1,
      'verse_id': 1,
      'text': 'glyphe-1',
      'char_type_name': 'word',
      'page_number': 1,
      'line_number': 1,
      'position_in_line': 1,
      'position_in_page': 1,
    },
    <String, dynamic>{
      'record_type': 'mushaf_word',
      'id': 32,
      'word_id': 3,
      'verse_id': 1,
      'text': 'glyphe-fin',
      'char_type_name': 'end',
      'page_number': 1,
      'line_number': 1,
      'position_in_line': 3,
      'position_in_page': 3,
    },
  ],
};

MushafSnapshot buildSnapshot() =>
    MushafSnapshot.fromSnapshotJson(buildSnapshotJson());

/// Table d'ordinaux correspondant au jeu de données ci-dessus.
VerseOrdinalTable buildOrdinals() =>
    const VerseOrdinalTable(<int, int>{1: 7, 2: 5});

MushafIndex buildIndex() => MushafIndex.fromSnapshot(
  snapshot: buildSnapshot(),
  ordinals: buildOrdinals(),
);
