@Tags(['platform-android'])
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/android/android_library_page.dart';
import 'package:squid_album/src/ui/android/android_media_card.dart';
import 'package:squid_album/src/ui/android/android_video_merge_page.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets(
    'merge ordering, covers and busy return protection survive failure',
    (tester) async {
      final videos = [_video(1), _video(2)];
      final backend = _MergeBackend(videos);
      await tester.pumpWidget(
        SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(AndroidLibraryPage));
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              AndroidVideoMergePage(backend: backend, videos: videos),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AndroidMediaThumbnail), findsNWidgets(2));
      expect(find.byTooltip('预览源视频'), findsNWidgets(2));
      final order = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      order.onReorderItem!(0, 1);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('保存合并视频'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('保存合并视频'));
      await tester.pump();
      expect(backend.order, [2, 1]);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AndroidVideoMergePage), findsOneWidget);
      backend.gate.completeError(StateError('synthetic merge failure'));
      await tester.pumpAndSettle();
      expect(find.textContaining('synthetic merge failure'), findsNothing);
      expect(find.byKey(const Key('android-notice-bubble')), findsOneWidget);
      expect(find.byType(AndroidVideoMergePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}

class _MergeBackend extends FakeBackend {
  _MergeBackend(List<MediaAsset> videos) : super(mediaItems: videos);
  final gate = Completer<MediaAsset>();
  List<int> order = [];
  @override
  Future<MediaAsset> saveMergedVideo(
    List<MediaAsset> videos, {
    String? preparedPath,
  }) {
    order = videos.map((item) => item.id).toList();
    return gate.future;
  }
}

MediaAsset _video(int id) => MediaAsset(
  id: id,
  sha256: 'missing-video-$id',
  originalName: '$id.mp4',
  storagePath: 'C:/nonexistent/$id.mp4',
  kind: MediaKind.video,
  importedAt: DateTime(2026, 10, 13),
  gameName: 'Game',
  favorite: false,
  tags: const [],
);
