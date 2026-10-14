@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/platform_ui.dart';
import 'package:squid_album/src/rust/models.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets(
    'long press keeps album, tag, export and delete actions reachable',
    (tester) async {
      final backend = FakeBackend(mediaItems: [_image()]);
      await tester.pumpWidget(
        SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('android-media-1')));
      await tester.pumpAndSettle();
      for (final action in [
        '复制到相册',
        '移动到相册',
        '收藏',
        '新增标签',
        '覆盖标签',
        '导出',
        '删除',
      ]) {
        expect(find.text(action), findsOneWidget);
      }
      await tester.tap(find.text('新增标签'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '新标签');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(backend.tagUpdates[1], ['Existing', '新标签']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
  testWidgets('batch select all and inversion preserve the media subtree', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: [_image()]);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('android-media-1'));
    final element = tester.element(card);
    await tester.tap(find.byKey(const Key('android-select-media')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
    expect(tester.element(card), same(element));
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('反选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
    expect(tester.element(card), same(element));
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}

MediaAsset _image() => MediaAsset(
  id: 1,
  sha256: 'image-fixture',
  originalName: 'test.png',
  storagePath: 'C:/nonexistent/image.png',
  kind: MediaKind.image,
  importedAt: DateTime(2026, 10, 13),
  gameName: 'Game',
  favorite: false,
  tags: const ['Existing'],
);
