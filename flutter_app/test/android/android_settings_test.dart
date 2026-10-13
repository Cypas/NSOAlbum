import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/platform_ui.dart';
import 'package:squid_album/src/ui/android/android_settings_page.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets('Android retains author information and tag creation', (
    tester,
  ) async {
    final backend = _TagBackend();
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    final settingsScroll = find
        .descendant(
          of: find.byType(AndroidSettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('android-manage-tags')),
      320,
      scrollable: settingsScroll,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('android-about-card')),
      200,
      scrollable: settingsScroll,
    );
    expect(find.text('Cypas_Nya'), findsOneWidget);
    expect(find.text('小鱿鱿bot作者'), findsOneWidget);
    expect(find.byKey(const Key('android-about-github-link')), findsOneWidget);
    expect(
      find.byKey(const Key('android-about-feedback-link')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('android-manage-tags')),
      -200,
      scrollable: settingsScroll,
    );
    await tester.tap(find.byKey(const Key('android-manage-tags')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新增标签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '独立标签');
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(backend.createdTags, ['独立标签']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}

class _TagBackend extends FakeBackend {
  _TagBackend() : super(mediaItems: []);
  final createdTags = <String>[];
  @override
  Future<int> createTag(String name) async {
    createdTags.add(name);
    return createdTags.length;
  }
}
