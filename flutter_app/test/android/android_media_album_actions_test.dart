@Tags(['platform-android'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/android/android_media_album_actions.dart';

void main() {
  test('moving without a manual source explains that it was copied', () {
    expect(
      androidMediaAlbumActionMessage(move: true, removedSource: false, zh: true),
      '已复制到相册；当前列表没有可移出的普通相册。',
    );
  });

  test('moving from a manual source reports a move', () {
    expect(
      androidMediaAlbumActionMessage(move: true, removedSource: true, zh: true),
      '已移动到相册。',
    );
  });
}
