@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_settings_page.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets('tag merge confirms the chosen sources before committing', (
    tester,
  ) async {
    final backend = _MergeBackend();
    await _open(tester, backend);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并自定义标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('One'));
    await tester.tap(find.text('Two'));
    await tester.enterText(
      find.byKey(const Key('android-merge-tag-name')),
      'Merged',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并').last);
    await tester.pumpAndSettle();
    expect(backend.mergedIds, isEmpty);
    await tester.tap(find.text('确认合并'));
    await tester.pumpAndSettle();
    expect(backend.mergedIds, [1, 2]);
    expect(backend.mergedName, 'Merged');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('custom tag rename and deletion stay behind confirmation', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: [],
      tagUsageItems: [
        TagUsageSummary(
          id: 1,
          name: 'Old tag',
          imageCount: BigInt.one,
          videoCount: BigInt.zero,
        ),
      ],
    );
    await _open(tester, backend);
    await tester.tap(find.byKey(const ValueKey('android-tag-actions-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'New tag');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('New tag'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('android-tag-actions-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('New tag'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('android-tag-actions-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(find.text('New tag'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('game tag uses display replacement rather than media rename', (
    tester,
  ) async {
    final backend = FakeBackend(
      mediaItems: [
        MediaAsset(
          id: 1,
          sha256: 'game-fixture',
          originalName: 'test.png',
          storagePath: 'C:/nonexistent/image.png',
          kind: MediaKind.image,
          importedAt: DateTime(2026, 10, 13),
          gameName: 'Original game',
          favorite: false,
          tags: const [],
        ),
      ],
    );
    await _open(tester, backend);
    await tester.tap(
      find.byKey(const ValueKey('android-game-replace-Original game')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Displayed game');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('Displayed game'), findsOneWidget);
    expect(backend.mediaItems!.single.storagePath, 'C:/nonexistent/image.png');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}

class _MergeBackend extends FakeBackend {
  _MergeBackend()
    : super(
        mediaItems: [],
        tagUsageItems: [
          for (final entry in [(1, 'One'), (2, 'Two')])
            TagUsageSummary(
              id: entry.$1,
              name: entry.$2,
              imageCount: BigInt.zero,
              videoCount: BigInt.zero,
            ),
        ],
      );
  List<int> mergedIds = [];
  String? mergedName;
  @override
  Future<void> mergeTags(List<int> tagIds, String targetName) async {
    mergedIds = tagIds;
    mergedName = targetName;
  }
}

Future<void> _open(WidgetTester tester, FakeBackend backend) async {
  await tester.pumpWidget(
    SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(NavigationDestination).at(3));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('android-manage-tags')),
    320,
    scrollable: find
        .descendant(
          of: find.byType(AndroidSettingsPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(find.byKey(const Key('android-manage-tags')));
  await tester.pumpAndSettle();
}
