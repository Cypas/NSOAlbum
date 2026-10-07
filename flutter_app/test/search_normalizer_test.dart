import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/search/search_normalizer.dart';

void main() {
  test('matches simplified queries against traditional content', () {
    expect(normalizedTextContains('祭典活動與遊戲畫面', '祭典活动'), isTrue);
    expect(normalizedTextContains('慶典 Ranked', '庆典'), isTrue);
  });

  test('matches traditional queries against simplified content', () {
    expect(normalizedTextContains('祭典活动与游戏画面', '遊戲畫面'), isTrue);
    expect(normalizedTextContains('庆典 Ranked', '慶典'), isTrue);
  });

  test('keeps Latin matching case insensitive', () {
    expect(normalizedTextContains('Ranked Battle', 'RANKED'), isTrue);
  });
}
