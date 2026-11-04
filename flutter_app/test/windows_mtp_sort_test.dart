import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/windows_mtp_import.dart';
import 'package:squid_album/src/ui/home_shell.dart'
    show
        MtpGameSortCriterion,
        filterAndSortMtpGames,
        committedMtpSearchQuery;

NintendoMtpMediaEntry _entry(String game, String file, int size) =>
    NintendoMtpMediaEntry(
      gameName: game,
      fileName: file,
      sizeBytes: size,
      capturedAt: null,
    );

void main() {
  final folders = {
    'Alpha': [_entry('Alpha', 'a1.jpg', 10)],
    'Beta': [_entry('Beta', 'b1.jpg', 900), _entry('Beta', 'b2.jpg', 900)],
    'Gamma': [
      _entry('Gamma', 'g1.jpg', 50),
      _entry('Gamma', 'g2.jpg', 50),
      _entry('Gamma', 'g3.jpg', 50),
    ],
  };

  List<String> names(
    MtpGameSortCriterion criterion, {
    bool ascending = true,
    String query = '',
  }) => filterAndSortMtpGames(
    folders,
    query: query,
    criterion: criterion,
    ascending: ascending,
  ).map((entry) => entry.key).toList();

  test('Switch import search filters game names without losing others', () {
    expect(names(MtpGameSortCriterion.name, query: 'ga'), ['Gamma']);
    expect(names(MtpGameSortCriterion.name, query: 'ET'), ['Beta']);
  });

  test('Switch import search commits only after IME composition ends', () {
    const committed = 'Alpha';
    final composing = TextEditingValue(
      text: 'zhong',
      composing: TextRange(start: 0, end: 5),
    );
    expect(committedMtpSearchQuery(composing, committed), committed);
    expect(
      committedMtpSearchQuery(
        const TextEditingValue(text: '中文'),
        committed,
      ),
      '中文',
    );
  });

  test(
    'Switch import sorts by name count and total size in both directions',
    () {
      expect(names(MtpGameSortCriterion.name), ['Alpha', 'Beta', 'Gamma']);
      expect(names(MtpGameSortCriterion.name, ascending: false), [
        'Gamma',
        'Beta',
        'Alpha',
      ]);
      expect(names(MtpGameSortCriterion.count, ascending: false), [
        'Gamma',
        'Beta',
        'Alpha',
      ]);
      expect(names(MtpGameSortCriterion.count), ['Alpha', 'Beta', 'Gamma']);
      expect(names(MtpGameSortCriterion.size, ascending: false), [
        'Beta',
        'Gamma',
        'Alpha',
      ]);
      expect(names(MtpGameSortCriterion.size), ['Alpha', 'Gamma', 'Beta']);
    },
  );
}
