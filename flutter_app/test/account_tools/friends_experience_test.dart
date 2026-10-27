import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/account_tools/nintendo_friends_page.dart';

import '../layout_viewport.dart';
import 'account_tools_pages_test.dart' show ToolsBackend, app, profile;

void main() {
  test('last online distinguishes minute hour day and calendar boundaries', () {
    final now = DateTime.utc(2026, 10, 27, 12);
    for (final entry in <(Duration, String, String)>[
      (Duration.zero, '1分钟前', '1 minute ago'),
      (const Duration(seconds: 59), '1分钟前', '1 minute ago'),
      (const Duration(minutes: 1), '1分钟前', '1 minute ago'),
      (const Duration(minutes: 59), '59分钟前', '59 minutes ago'),
      (const Duration(hours: 1), '1小时前', '1 hour ago'),
      (const Duration(hours: 23, minutes: 59), '23小时前', '23 hours ago'),
      (const Duration(days: 1), '1天前在线', '1 day ago'),
      (const Duration(days: 29, hours: 23), '29天前在线', '29 days ago'),
    ]) {
      expect(
        formatFriendLastOnline(
          now.subtract(entry.$1),
          now: now,
          english: false,
        ),
        entry.$2,
      );
      expect(
        formatFriendLastOnline(now.subtract(entry.$1), now: now),
        entry.$3,
      );
    }
    expect(
      formatFriendLastOnline(
        now.add(const Duration(minutes: 2)),
        now: now,
        english: false,
      ),
      '1分钟前',
    );
    final old = now.subtract(const Duration(days: 30)).toLocal();
    final expected =
        '${old.year}-'
        '${old.month.toString().padLeft(2, '0')}-'
        '${old.day.toString().padLeft(2, '0')} '
        '${old.hour.toString().padLeft(2, '0')}:00:00';
    expect(
      formatFriendLastOnline(now.subtract(const Duration(days: 30)), now: now),
      expected,
    );
  });

  for (final mobile in [true, false]) {
    testWidgets(
      'complete friend bubble contains count toggle and all cards mobile=$mobile',
      (tester) async {
        final backend = ToolsBackend(
          friends: const [
            NintendoFriend(
              friendId: 'in-bubble',
              nickname: 'Inside bubble',
              note: '',
              isFavorite: false,
              presence: 'ONLINE',
            ),
          ],
        );
        await tester.pumpWidget(
          app(
            NintendoFriendsPage(
              backend: backend,
              profile: profile,
              mobile: mobile,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final bubble = find.byKey(const Key('friend-group-bubble-online'));
        expect(
          find.descendant(of: bubble, matching: find.text('在线好友')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: bubble,
            matching: find.byKey(const Key('friend-group-count-online')),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('friend-card-open-in-bubble')),
          findsOneWidget,
        );
        final toggle = find.byKey(const Key('friend-group-toggle-online'));
        expect(find.descendant(of: bubble, matching: toggle), findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('Inside bubble'), findsNothing);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('Inside bubble'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('offline group orders recent first and missing times last', (
    tester,
  ) async {
    final backend = ToolsBackend(
      friends: [
        const NintendoFriend(
          friendId: 'unknown',
          nickname: 'A unknown',
          note: '',
          isFavorite: false,
          presence: 'OFFLINE',
        ),
        NintendoFriend(
          friendId: 'older',
          nickname: 'B older',
          note: '',
          isFavorite: false,
          presence: 'OFFLINE',
          logoutAt: DateTime.utc(2026, 10, 26),
        ),
        NintendoFriend(
          friendId: 'recent',
          nickname: 'Z recent',
          note: '',
          isFavorite: false,
          presence: 'OFFLINE',
          logoutAt: DateTime.utc(2026, 10, 27),
        ),
      ],
    );
    await tester.pumpWidget(
      app(
        NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('离线好友'));
    await tester.pumpAndSettle();
    final cards = find
        .byWidgetPredicate(
          (widget) =>
              widget.key is Key &&
              widget.key.toString().contains('friend-card-open-'),
        )
        .evaluate()
        .map((element) => element.widget.key)
        .toList();
    expect(cards, const [
      Key('friend-card-open-recent'),
      Key('friend-card-open-older'),
      Key('friend-card-open-unknown'),
    ]);
  });

  testWidgets('friend bubble retains lazy rendering for large categories', (
    tester,
  ) async {
    final backend = ToolsBackend(
      friends: List.generate(
        1000,
        (id) => NintendoFriend(
          friendId: 'lazy-$id',
          nickname: 'Friend ${id.toString().padLeft(4, '0')}',
          note: '',
          isFavorite: false,
          presence: 'ONLINE',
        ),
      ),
    );
    await tester.pumpWidget(
      app(
        NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Friend 0000'), findsOneWidget);
    expect(find.text('Friend 0999'), findsNothing);
    expect(find.byType(Card).evaluate().length, lessThan(80));
  });

  testWidgets(
    'add dialog opens before own code and allows lookup in parallel',
    (tester) async {
      final backend = _AsyncOwnCodeBackend()
        ..ownGate = Completer<NintendoFriendCodeSnapshot>();
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.person_add_alt_1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Switch码获取中...'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456789012');
      await tester.tap(find.text('查询'));
      await tester.pump();
      expect(backend.friendCodeLookups, ['clicked-b:123456789012']);
      expect(find.text('Lookup preview'), findsOneWidget);
      final send = find.widgetWithText(FilledButton, '确认发送');
      expect(send, findsOneWidget);
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      expect(backend.friendAccounts, ['clicked-b']);
      backend.ownGate!.complete(
        const NintendoFriendCodeSnapshot(friendCode: '1111-2222-3333', url: ''),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
      expect(backend.friendRequests, isEmpty);
    },
  );

  testWidgets('own code failure retries then copies the formatted code', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final backend = _AsyncOwnCodeBackend()..ownFailure = true;
    await tester.pumpWidget(
      app(
        NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('重试获取Switch码'), findsOneWidget);
    backend.ownFailure = false;
    await tester.tap(find.text('重试获取Switch码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SW-1111-2222-3333'), findsOneWidget);
    await tester.tap(find.byTooltip('复制Switch码'));
    await tester.pumpAndSettle();
    expect(copied, 'SW-1111-2222-3333');
    expect(find.text('已复制Switch码'), findsOneWidget);
    expect(backend.friendRequests, isEmpty);
  });

  testWidgets('closing own-code loading cancels and ignores its late result', (
    tester,
  ) async {
    final backend = _AsyncOwnCodeBackend()
      ..ownGate = Completer<NintendoFriendCodeSnapshot>();
    await tester.pumpWidget(
      app(
        NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(backend.cancelled, contains(backend.ownOperations.single));
    backend.ownGate!.complete(
      const NintendoFriendCodeSnapshot(friendCode: '1111-2222-3333', url: ''),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing friend snapshot leaves the relationship unverified', (
    tester,
  ) async {
    final backend = _AsyncOwnCodeBackend()..failRefresh = true;
    await tester.pumpWidget(
      app(
        NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456789012');
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    expect(find.text('Lookup preview'), findsOneWidget);
    expect(find.textContaining('好友关系待核验'), findsOneWidget);
    final send = find.widgetWithText(FilledButton, '确认发送');
    expect(send, findsOneWidget);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    expect(backend.friendAccounts, ['clicked-b']);
    expect(backend.friendRequests, isEmpty);
  });

  testWidgets(
    'lookup spinner and cancellation ignore a changed-code response',
    (tester) async {
      final backend = _AsyncOwnCodeBackend()
        ..lookupGate = Completer<NintendoFriendCodeUser>();
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.person_add_alt_1));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456789012');
      await tester.tap(find.text('查询'));
      await tester.pump();
      expect(
        find.descendant(
          of: find.widgetWithText(FilledButton, '查询中...'),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '123456789013');
      await tester.pump();
      backend.lookupGate!.complete(
        const NintendoFriendCodeUser(
          friendId: 'stale',
          nickname: 'Stale preview',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Stale preview'), findsNothing);
      expect(find.text('确认发送'), findsNothing);
      expect(backend.friendRequests, isEmpty);
    },
  );

  testWidgets('late own code identifying self disables a parallel preview', (
    tester,
  ) async {
    final backend = _AsyncOwnCodeBackend()
      ..ownGate = Completer<NintendoFriendCodeSnapshot>();
    await tester.pumpWidget(
      app(
        NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), '123456789012');
    await tester.tap(find.text('查询'));
    await tester.pump();
    backend.ownGate!.complete(
      const NintendoFriendCodeSnapshot(friendCode: '123456789012', url: ''),
    );
    await tester.pumpAndSettle();
    expect(find.text('不能向自己发送好友申请。'), findsOneWidget);
    expect(find.text('确认发送'), findsNothing);
    expect(backend.friendRequests, isEmpty);
  });

  for (final language in ['zh', 'en']) {
    testWidgets('add dialog fits narrow large-text layouts ($language)', (
      tester,
    ) async {
      await useLayoutTestViewport(tester, const Size(320, 1100));
      final backend = _AsyncOwnCodeBackend();
      await tester.pumpWidget(
        app(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 1100),
              textScaler: TextScaler.linear(2),
            ),
            child: NintendoFriendsPage(
              backend: backend,
              profile: profile,
              mobile: true,
            ),
          ),
          locale: Locale(language),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.person_add_alt_1));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

class _AsyncOwnCodeBackend extends ToolsBackend {
  Completer<NintendoFriendCodeSnapshot>? ownGate;
  bool ownFailure = false;
  final ownOperations = <String>[];

  @override
  Future<NintendoFriendCodeSnapshot> loadNintendoFriendCode(
    String accountId,
    String operationId,
  ) async {
    ownOperations.add(operationId);
    if (ownFailure) throw StateError('network unavailable');
    if (ownGate != null) return ownGate!.future;
    return const NintendoFriendCodeSnapshot(
      friendCode: '111122223333',
      url: '',
    );
  }
}
