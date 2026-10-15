import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/backend/nintendo_account_tools_backend.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/account_tools/nintendo_friends_page.dart';
import 'package:squid_album/src/ui/account_tools/gear_seed_page.dart';
import 'package:squid_album/src/ui/account_tools/account_tool_frame.dart';

import '../home_shell_test.dart' show FakeBackend;

const profile = NintendoAccountProfile(accountId: 'clicked-b', nickname: 'B');

Widget app(Widget page) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: page,
);

void main() {
  testWidgets(
    'friends are starred-first with stable names and hidden presence is explicit',
    (tester) async {
      final backend = ToolsBackend(
        friends: [
          const NintendoFriend(
            friendId: 'z',
            nickname: 'Same',
            note: 'unstarred',
            isFavorite: false,
            presence: 'ONLINE',
          ),
          const NintendoFriend(
            friendId: 'b',
            nickname: 'Same',
            note: 'second id',
            isFavorite: true,
            presence: 'ONLINE',
          ),
          const NintendoFriend(
            friendId: 'a',
            nickname: 'Same',
            note: 'first id',
            isFavorite: true,
            presence: 'ONLINE',
          ),
          const NintendoFriend(
            friendId: 'hidden',
            nickname: 'Hidden friend',
            note: '',
            isFavorite: false,
            presence: 'UNKNOWN',
          ),
        ],
      );
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(
            backend: backend,
            profile: profile,
            mobile: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('first id')).dy,
        lessThan(tester.getTopLeft(find.text('second id')).dy),
      );
      expect(
        tester.getTopLeft(find.text('second id')).dy,
        lessThan(tester.getTopLeft(find.text('unstarred')).dy),
      );
      expect(find.text('Hidden friend'), findsNothing);
      await tester.tap(find.text('离线好友'));
      await tester.pumpAndSettle();
      expect(find.text('状态未公开'), findsOneWidget);
      expect(find.textContaining('上次在线：'), findsNothing);
    },
  );

  testWidgets(
    'leaving friends cancels its request and ignores a late snapshot',
    (tester) async {
      final gate = Completer<NintendoFriendsSnapshot>();
      final backend = ToolsBackend()..friendGate = gate;
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(
            backend: backend,
            profile: profile,
            mobile: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        backend.cancelled.where((id) => id.startsWith('friends-')),
        isNotEmpty,
      );
      gate.complete(
        NintendoFriendsSnapshot(
          friends: const [],
          updatedAt: DateTime.utc(2026, 10, 16),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('custom browser back owner is not bypassed by the mobile frame', (
    tester,
  ) async {
    var backs = 0;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => PopScope(
                  canPop: false,
                  onPopInvokedWithResult: (didPop, _) {
                    if (!didPop) backs++;
                  },
                  child: AccountToolFrame(
                    mobile: true,
                    title: 'browser',
                    onBack: () => backs++,
                    child: const Text('web history'),
                  ),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(backs, 1);
    expect(find.text('web history'), findsOneWidget);
  });
  testWidgets(
    'friends groups retain the last snapshot after a failed refresh',
    (tester) async {
      final backend = ToolsBackend();
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(
            backend: backend,
            profile: profile,
            mobile: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(backend.friendAccounts, ['clicked-b']);
      expect(find.text('在线好友'), findsOneWidget);
      expect(find.text('离线好友'), findsOneWidget);
      expect(find.text('Online friend'), findsOneWidget);
      expect(find.text('Offline friend'), findsNothing);
      await tester.tap(find.text('离线好友'));
      await tester.pumpAndSettle();
      expect(find.text('Offline friend'), findsOneWidget);
      backend.failRefresh = true;
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(find.text('Online friend'), findsOneWidget);
      expect(find.text('Offline friend'), findsOneWidget);
      expect(find.textContaining('请求未完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saving cancellation is not reported as an export failure', (
    tester,
  ) async {
    final backend = ToolsBackend();
    var saves = 0;
    await tester.pumpWidget(
      app(
        GearSeedPage(
          backend: backend,
          profile: profile,
          mobile: false,
          saveExport: (payload) async {
            saves++;
            expect(payload.fileName, 'gear_123_1.json');
            return null;
          },
        ),
      ),
    );
    await tester.tap(find.text('下载喷三观星文件'));
    await tester.pumpAndSettle();
    expect(backend.seedAccounts, ['clicked-b']);
    expect(saves, 1);
    expect(find.textContaining('请求未完成'), findsNothing);
    expect(find.text('已保存'), findsNothing);
  });

  testWidgets('export cancellation ignores a late network completion', (
    tester,
  ) async {
    final backend = ToolsBackend()..seedGate = Completer<SeedExportPayload>();
    var saved = false;
    await tester.pumpWidget(
      app(
        GearSeedPage(
          backend: backend,
          profile: profile,
          mobile: false,
          saveExport: (_) async {
            saved = true;
            return 'chosen.json';
          },
        ),
      ),
    );
    await tester.tap(find.text('下载喷三观星文件'));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pump();
    backend.seedGate!.complete(backend.payload);
    await tester.pumpAndSettle();
    expect(saved, isFalse);
    expect(backend.cancelled, isNotEmpty);
    expect(find.text('操作已取消。'), findsOneWidget);
  });
}

class ToolsBackend extends FakeBackend implements NintendoAccountToolsBackend {
  ToolsBackend({this.friends}) : super(mediaItems: []);
  final List<NintendoFriend>? friends;
  Completer<NintendoFriendsSnapshot>? friendGate;
  bool failRefresh = false;
  final friendAccounts = <String>[];
  final seedAccounts = <String>[];
  final cancelled = <String>[];
  Completer<SeedExportPayload>? seedGate;
  SeedExportPayload get payload => SeedExportPayload(
    fileName: 'gear_123_1.json',
    bytes: Uint8List.fromList([123, 125]),
  );

  @override
  Future<NintendoFriendsSnapshot> loadNintendoFriends(
    String accountId,
    String operationId,
  ) async {
    friendAccounts.add(accountId);
    if (failRefresh) throw StateError('network unavailable');
    if (friendGate != null) return friendGate!.future;
    return NintendoFriendsSnapshot(
      friends:
          friends ??
          [
            NintendoFriend(
              friendId: '1',
              nickname: 'Online friend',
              note: 'note',
              isFavorite: false,
              presence: 'ONLINE',
              gameName: 'Splatoon 3',
            ),
            NintendoFriend(
              friendId: '2',
              nickname: 'Offline friend',
              note: '',
              isFavorite: true,
              presence: 'OFFLINE',
            ),
          ],
      updatedAt: DateTime.utc(2026, 10, 15, 1, 2, 3),
    );
  }

  @override
  Future<Uint8List> loadNintendoFriendAvatar(
    String accountId,
    String friendId,
    String operationId,
  ) async => Uint8List(0);

  @override
  Future<SeedExportPayload> prepareSeedExport(
    String accountId,
    String operationId,
  ) async {
    seedAccounts.add(accountId);
    return seedGate == null ? payload : seedGate!.future;
  }

  @override
  Future<SplatNetWebSession> prepareSplatNetSession(
    String accountId,
    String operationId, {
    bool forceRefresh = false,
  }) => throw UnimplementedError();

  @override
  Future<void> cancelAccountToolOperation(String operationId) async =>
      cancelled.add(operationId);
}
