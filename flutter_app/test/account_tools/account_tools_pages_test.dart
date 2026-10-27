import 'dart:async';
import 'dart:convert';
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
import 'package:squid_album/src/ui/android/android_theme.dart';

import '../home_shell_test.dart' show FakeBackend;
import '../layout_viewport.dart';

const profile = NintendoAccountProfile(accountId: 'clicked-b', nickname: 'B');

Widget app(Widget page, {Locale locale = const Locale('zh')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: page,
);

void main() => registerAccountToolsPageTests();

void registerAccountToolsPageTests({bool layoutOnly = false}) {
  test('friend offline time uses relative text only for less than 30 days', () {
    final now = DateTime(2026, 10, 25, 12);
    expect(formatFriendLastOnline(now, now: now, english: false), '1分钟前');
    expect(
      formatFriendLastOnline(now.subtract(const Duration(days: 29)), now: now),
      '29 days ago',
    );
    expect(
      formatFriendLastOnline(now.subtract(const Duration(days: 30)), now: now),
      '2026-09-25 12:00:00',
    );
  });

  for (final language in ['zh', 'en']) {
    for (final width in [320.0, 360.0, 412.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'mobile friends $language width=$width scale=$scale keep centered avatars and readable rows',
          (tester) async {
            await useLayoutTestViewport(tester, Size(width, 1300));
            final backend = ToolsBackend(
              friends: List.generate(
                3,
                (id) => NintendoFriend(
                  friendId: 'matrix-$id',
                  nickname: 'Friend $id',
                  note: 'Long note with meaningful text',
                  isFavorite: false,
                  presence: 'ONLINE',
                  gameName: 'A deliberately long game name with several words',
                ),
              ),
            );
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                theme: androidTheme('ocean'),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: NintendoFriendsPage(
                  backend: backend,
                  profile: profile,
                  mobile: true,
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.getSize(find.byType(Scaffold).first).width,
              width,
              reason: 'The matrix must render at its requested viewport.',
            );
            final avatar = find.byKey(const ValueKey('matrix-0:'));
            final card = find
                .ancestor(of: avatar, matching: find.byType(Card))
                .first;
            expect(
              tester.getCenter(avatar).dx,
              closeTo(tester.getCenter(card).dx, 1),
            );
            final name = tester.widget<Text>(find.text('Friend 0'));
            expect(name.textAlign, TextAlign.center);
            final game = tester
                .widgetList<Text>(
                  find.text('A deliberately long game name with several words'),
                )
                .first;
            expect(game.maxLines, 2);
            expect(find.text(language == 'zh' ? '在线' : 'Online'), findsNothing);
            final firstTop = tester.getTopLeft(find.text('Friend 0')).dy;
            final thirdTop = tester.getTopLeft(find.text('Friend 2')).dy;
            if (scale == 1 && width >= 360) {
              expect(
                thirdTop,
                firstTop,
                reason: 'Normal phone layout should fit three cards.',
              );
            } else {
              expect(
                thirdTop,
                greaterThan(firstTop),
                reason: 'Narrow or enlarged-text layouts reduce columns.',
              );
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  if (layoutOnly) return;

  testWidgets('SplatNet restrictions preserve the ordinary friend list', (
    tester,
  ) async {
    final backend = ToolsBackend()
      ..friendGate = Completer<NintendoFriendsSnapshot>();
    await tester.pumpWidget(
      app(
        NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
      ),
    );
    await tester.pump();
    backend.friendGate!.complete(
      NintendoFriendsSnapshot(
        friends: const [
          NintendoFriend(
            friendId: 'ordinary',
            nickname: 'Ordinary friend',
            note: '',
            isFavorite: false,
            presence: 'ONLINE',
          ),
        ],
        updatedAt: DateTime.utc(2026, 10, 22),
        activityError: 'splatnet_access_restricted',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ordinary friend'), findsOneWidget);
    expect(find.textContaining('鱿鱼圈访问受限'), findsOneWidget);
    expect(find.textContaining('重新登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('friend-code input is normalized to twelve digits', () {
    expect(normalizeNintendoFriendCode('123456789012'), '123456789012');
    expect(normalizeNintendoFriendCode('1234-5678-9012'), '123456789012');
    expect(normalizeNintendoFriendCode('SW-1234-5678-9012'), '123456789012');
    expect(normalizeNintendoFriendCode('sw-1234-5678-9012'), '123456789012');
    expect(normalizeNintendoFriendCode('1234 5678 9012'), '123456789012');
    expect(normalizeNintendoFriendCode('1234－5678－9012'), '123456789012');
    expect(normalizeNintendoFriendCode('1234-5678-901'), isNull);
    expect(normalizeNintendoFriendCode('1234-5678-90123'), isNull);
    expect(normalizeNintendoFriendCode(''), isNull);
    expect(normalizeNintendoFriendCode('１２３４５６７８９０１２'), isNull);
  });

  for (final language in ['zh', 'en']) {
    testWidgets(
      'invalid friend code shows lowercase format guidance without querying ($language)',
      (tester) async {
        final backend = ToolsBackend();
        await tester.pumpWidget(
          app(
            NintendoFriendsPage(
              backend: backend,
              profile: profile,
              mobile: true,
            ),
            locale: Locale(language),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.person_add_alt_1));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'sw-1234-5678-901');
        await tester.tap(find.text(language == 'zh' ? '查询' : 'Look up'));
        await tester.pumpAndSettle();
        expect(backend.friendCodeLookups, isEmpty);
        expect(
          find.text(
            language == 'zh'
                ? '请输入 sw-xxxx-xxxx-xxxx 格式的好友码。'
                : 'Enter a friend code in the format sw-xxxx-xxxx-xxxx.',
          ),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '确认发送' : 'Send request'),
          findsNothing,
        );
      },
    );
  }

  testWidgets(
    'friend-code lookup submits twelve digits and waits for confirmation',
    (tester) async {
      final backend = ToolsBackend();
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byIcon(Icons.person_add_alt_1));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'SW-1234－5678－9012');
      await tester.tap(find.text('查询'));
      await tester.pumpAndSettle();
      expect(backend.friendCodeLookups, ['clicked-b:123456789012']);
      expect(find.text('Lookup preview'), findsOneWidget);
      expect(find.text('确认发送'), findsOneWidget);
      expect(backend.friendRequests, isEmpty);
      await tester.tap(find.text('确认发送'));
      await tester.pumpAndSettle();
      expect(backend.friendRequests, ['clicked-b:synthetic-lookup']);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('好友申请已发送。'), findsOneWidget);
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets(
      'existing friend preview shows an avatar and cannot send another request ($language)',
      (tester) async {
        final backend = ToolsBackend()..lookupFriendId = '1';
        await tester.pumpWidget(
          app(
            NintendoFriendsPage(
              backend: backend,
              profile: profile,
              mobile: true,
            ),
            locale: Locale(language),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.person_add_alt_1));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '1234-5678-9012');
        await tester.tap(find.text(language == 'zh' ? '查询' : 'Look up'));
        await tester.pumpAndSettle();
        expect(find.text('Lookup preview'), findsOneWidget);
        expect(
          find.text(language == 'zh' ? '已是好友' : 'Already friends'),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '确认发送' : 'Send request'),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(CircleAvatar),
          ),
          findsOneWidget,
        );
        expect(backend.friendAccounts, ['clicked-b']);
        expect(backend.friendRequests, isEmpty);
      },
    );
  }

  testWidgets(
    'editing a queried code invalidates its preview and send action',
    (tester) async {
      final backend = ToolsBackend();
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
      await tester.enterText(find.byType(TextField), '123456789013');
      await tester.pumpAndSettle();
      expect(find.text('Lookup preview'), findsNothing);
      expect(find.text('确认发送'), findsNothing);
      expect(find.text('查询'), findsOneWidget);
      expect(backend.friendRequests, isEmpty);
    },
  );

  testWidgets('lookup uses the existing friend snapshot without reloading it', (
    tester,
  ) async {
    final backend = ToolsBackend();
    await tester.pumpWidget(
      app(
        NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    backend.failRefresh = true;
    await tester.enterText(find.byType(TextField), '123456789012');
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    expect(find.text('确认发送'), findsOneWidget);
    expect(backend.friendAccounts, ['clicked-b']);
    expect(backend.friendRequests, isEmpty);
  });

  testWidgets('the current account code cannot be used to request itself', (
    tester,
  ) async {
    final backend = ToolsBackend();
    await tester.pumpWidget(
      app(
        NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sw-1111-2222-3333');
    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    expect(find.text('不能向自己发送好友申请。'), findsOneWidget);
    expect(find.text('确认发送'), findsNothing);
    expect(backend.friendCodeLookups, isEmpty);
    expect(backend.friendRequests, isEmpty);
  });

  testWidgets('a rejected request preserves the preview and permits retry', (
    tester,
  ) async {
    final backend = ToolsBackend()..requestAccepted = false;
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
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Lookup preview'), findsOneWidget);
    expect(find.text('123456789012'), findsOneWidget);
    expect(find.text('好友申请已发送。'), findsNothing);
    backend.requestAccepted = true;
    backend.becameFriends = true;
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('已成为好友。'), findsOneWidget);
    expect(backend.friendRequests, [
      'clicked-b:synthetic-lookup',
      'clicked-b:synthetic-lookup',
    ]);
  });

  testWidgets('closing the preview cancels a pending lookup and ignores it', (
    tester,
  ) async {
    final backend = ToolsBackend()
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
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      backend.cancelled.where((id) => id.startsWith('friend-lookup-')),
      isNotEmpty,
    );
    backend.lookupGate!.complete(
      const NintendoFriendCodeUser(
        friendId: 'late-user',
        nickname: 'Late preview',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Late preview'), findsNothing);
    expect(backend.friendRequests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'two friend cards share a row on a normal phone and grow for text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = ToolsBackend(
        friends: [
          const NintendoFriend(
            friendId: 'a',
            nickname: 'First',
            note: 'long note with more than one line',
            isFavorite: false,
            presence: 'ONLINE',
          ),
          const NintendoFriend(
            friendId: 'b',
            nickname: 'Second',
            note: '',
            isFavorite: false,
            presence: 'ONLINE',
          ),
        ],
      );
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('First')).dy,
        tester.getTopLeft(find.text('Second')).dy,
      );
      expect(
        tester.getTopLeft(find.text('First')).dx,
        lessThan(tester.getTopLeft(find.text('Second')).dx),
      );
      final avatar = find.byKey(const ValueKey('a:'));
      final card = find.ancestor(of: avatar, matching: find.byType(Card)).first;
      expect(
        tester.getCenter(avatar).dx,
        closeTo(tester.getCenter(card).dx, 1),
      );
      expect(
        tester.widget<Text>(find.text('First')).textAlign,
        TextAlign.center,
      );
      expect(
        find.ancestor(of: find.text('First'), matching: find.byType(Card)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mobile friend cards use larger avatars and a Japanese-capable nickname fallback',
    (tester) async {
      tester.view.physicalSize = const Size(360, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = ToolsBackend(
        friends: const [
          NintendoFriend(
            friendId: 'jp',
            nickname: 'こんにちは',
            note: '',
            isFavorite: false,
            presence: 'ONLINE',
          ),
        ],
      );
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));

      final avatar = find.descendant(
        of: find.ancestor(of: find.text('こんにちは'), matching: find.byType(Card)),
        matching: find.byType(CircleAvatar),
      );
      expect(
        tester.widget<CircleAvatar>(avatar).radius,
        greaterThanOrEqualTo(28),
      );
      final name = tester.widget<Text>(find.text('こんにちは'));
      expect(name.locale?.languageCode, 'ja');
      expect(
        name.style?.fontSize,
        lessThan(
          Theme.of(tester.element(find.text('こんにちは')))
              .textTheme
              .titleMedium!
              .fontSize!,
        ),
      );
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(
            key: UniqueKey(),
            backend: ToolsBackend(
              friends: const [
                NintendoFriend(
                  friendId: 'cn',
                  nickname: '中文好友',
                  note: '',
                  isFavorite: false,
                  presence: 'ONLINE',
                ),
              ],
            ),
            profile: profile,
            mobile: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('中文好友')).locale, isNull);
    },
  );
  testWidgets('mobile friend detail scales avatar up and nickname down', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        NintendoFriendDetailPage(
          backend: ToolsBackend(),
          friend: const NintendoFriend(
            friendId: 'detail-scale',
            nickname: 'Friend detail',
            note: '',
            isFavorite: false,
            presence: 'ONLINE',
          ),
          accountId: 'clicked-b',
          mobile: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<CircleAvatar>(find.byType(CircleAvatar)).first.radius,
      60,
    );
    final name = tester.widget<Text>(find.text('Friend detail'));
    expect(name.style?.fontSize, 22);
  });
  testWidgets(
    'the whole friend card opens a detail page with editable metadata',
    (tester) async {
      final backend = ToolsBackend(
        friendPlayLog: [
          const NintendoFriendGame(
            name: 'Splatoon 3',
            imageUrl: 'https://example.invalid/play-log-1.png',
            totalPlayTimeMinutes: 321,
          ),
          const NintendoFriendGame(
            name: 'Mario Kart 8 Deluxe',
            imageUrl: 'https://example.invalid/play-log-2.png',
            totalPlayTimeMinutes: 92,
          ),
        ],
        friends: [
          NintendoFriend(
            friendId: 'detail',
            nickname: 'Detail friend',
            note: 'old note',
            isFavorite: true,
            presence: 'ONLINE',
            gameName: 'Splatoon 3',
            gameImageUrl: 'https://example.invalid/splatoon3.png',
            totalPlayTimeMinutes: 321,
            firstPlayedAt: DateTime.utc(2024, 3, 4),
            activity: 'REGULAR',
            inGameName: 'Inkling',
            friendshipSource: 'FRIEND_CODE',
            friendCreatedAt: DateTime.utc(2023, 7, 8),
          ),
        ],
      );
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Detail friend'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 1));
      expect(backend.friendPlayLogRequests, ['clicked-b:detail']);
      expect(find.text('好友详情'), findsOneWidget);
      expect(find.text('Detail friend'), findsOneWidget);
      expect(find.textContaining('321'), findsAtLeastNWidgets(1));
      await tester.scrollUntilVisible(find.text('游戏记录'), 180);
      expect(find.text('游戏记录'), findsOneWidget);
      expect(find.text('Splatoon 3'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey(
            'friend-game-image:https://example.invalid/splatoon3.png',
          ),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(find.textContaining('Inkling'), 180);
      expect(find.textContaining('Inkling'), findsOneWidget);
      expect(find.text('Mario Kart 8 Deluxe'), findsOneWidget);
      expect(find.textContaining('92'), findsOneWidget);
      await tester.scrollUntilVisible(find.textContaining('好友码'), 180);
      expect(find.textContaining('好友码'), findsOneWidget);
      expect(find.textContaining('2023'), findsOneWidget);
      expect(find.textContaining('2024'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('好友关系'), 180);
      expect(find.text('好友关系'), findsOneWidget);
    },
  );
  testWidgets(
    'saving a friend note keeps the closing editor alive through its animation',
    (tester) async {
      final backend = ToolsBackend();
      await tester.pumpWidget(
        app(
          NintendoFriendDetailPage(
            backend: backend,
            friend: const NintendoFriend(
              friendId: 'note-friend',
              nickname: 'Note friend',
              note: 'Original',
              isFavorite: false,
              presence: 'ONLINE',
            ),
            accountId: 'clicked-b',
            mobile: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('编辑备注'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Updated');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Updated'), findsOneWidget);
      expect(backend.notes, ['clicked-b:note-friend:Updated']);
    },
  );
  testWidgets(
    'friend detail reuses the list avatar and supports a full size preview',
    (tester) async {
      final backend = ToolsBackend()
        ..avatar = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        );
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
        ),
      );
      await tester.pumpAndSettle();
      final requests = backend.avatarRequests.length;
      await tester.tap(find.byKey(const Key('friend-avatar-open-1')));
      await tester.pumpAndSettle();
      expect(backend.avatarRequests.length, requests);
      await tester.tap(find.byType(CircleAvatar).last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-image-viewer-pages')), findsOneWidget);
      expect(find.byKey(const Key('app-image-viewer-save')), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    },
  );
  testWidgets('a failed note save keeps the draft open for retry or cancel', (
    tester,
  ) async {
    final backend = ToolsBackend()..noteError = StateError('synthetic failure');
    await tester.pumpWidget(
      app(
        NintendoFriendDetailPage(
          backend: backend,
          friend: const NintendoFriend(
            friendId: 'note-friend',
            nickname: 'Note friend',
            note: 'Original',
            isFavorite: false,
            presence: 'ONLINE',
          ),
          accountId: 'clicked-b',
          mobile: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑备注'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep my draft');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep my draft',
    );
    expect(find.text('Original'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Original'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('retrying a note keeps the draft and uses a fresh request', (
    tester,
  ) async {
    final backend = ToolsBackend()..noteError = StateError('synthetic failure');
    await tester.pumpWidget(
      app(
        NintendoFriendDetailPage(
          backend: backend,
          friend: const NintendoFriend(
            friendId: 'note-friend',
            nickname: 'Note friend',
            note: 'Original',
            isFavorite: false,
            presence: 'ONLINE',
          ),
          accountId: 'clicked-b',
          mobile: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑备注'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Retry my draft');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    backend.noteError = null;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Retry my draft'), findsOneWidget);
    expect(backend.noteOperations.toSet(), hasLength(2));
    expect(tester.takeException(), isNull);
  });
  testWidgets('friendship uses the source game and places friends since last', (
    tester,
  ) async {
    final backend = ToolsBackend();
    await tester.pumpWidget(
      app(
        NintendoFriendDetailPage(
          backend: backend,
          friend: NintendoFriend(
            friendId: 'source-friend',
            nickname: 'Source friend',
            note: '',
            isFavorite: false,
            presence: 'ONLINE',
            gameName: 'Current game',
            friendshipSource: 'IN_APP',
            friendshipGameName: 'Original game',
            inGameName: 'In game',
            friendCreatedAt: DateTime.utc(2022, 2, 3),
          ),
          accountId: 'clicked-b',
          mobile: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('来源游戏'), 150);
    final relationship = tester.widget<Text>(find.textContaining('来源游戏')).data!;
    expect(relationship, contains('Original game'));
    expect(relationship, isNot(contains('Current game')));
    expect(relationship.split('\n').last, startsWith('成为好友：'));
  });
  testWidgets('game history starts with six games and expands and collapses', (
    tester,
  ) async {
    final backend = ToolsBackend(
      friendPlayLog: [
        for (var i = 1; i <= 9; i++) NintendoFriendGame(name: 'Game $i'),
      ],
    );
    await tester.pumpWidget(
      app(
        NintendoFriendDetailPage(
          backend: backend,
          friend: const NintendoFriend(
            friendId: 'history',
            nickname: 'History friend',
            note: '',
            isFavorite: false,
            presence: 'ONLINE',
          ),
          accountId: 'clicked-b',
          mobile: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Game 6'), 150);
    expect(find.text('Game 7'), findsNothing);
    await tester.scrollUntilVisible(find.byIcon(Icons.expand_more), 150);
    await tester.ensureVisible(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Game 9'), 150);
    expect(find.text('Game 9'), findsOneWidget);
    await tester.scrollUntilVisible(find.byIcon(Icons.expand_less), 150);
    await tester.ensureVisible(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(find.text('Game 9'), findsNothing);
    expect(find.text('记录范围取决于好友的隐私设置。'), findsOneWidget);
  });
  testWidgets('game images use the shared backend cache across friends', (
    tester,
  ) async {
    final backend =
        ToolsBackend(
            friendPlayLog: const [
              NintendoFriendGame(
                name: 'Shared game',
                imageUrl: 'https://example.invalid/game.png',
              ),
              NintendoFriendGame(
                name: 'Shared game',
                imageUrl: 'https://example.invalid/game.png',
              ),
            ],
          )
          ..avatar = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          );
    Future<void> show(String id) async {
      await tester.pumpWidget(
        app(
          NintendoFriendDetailPage(
            key: ValueKey(id),
            backend: backend,
            friend: NintendoFriend(
              friendId: id,
              nickname: id,
              note: '',
              isFavorite: false,
              presence: 'ONLINE',
            ),
            accountId: 'clicked-b',
            mobile: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Shared game').first, 150);
      await tester.pumpAndSettle();
    }

    await show('first-friend');
    expect(backend.gameImageRequests, ['Shared game']);
    final image = tester.widget<Image>(
      find
          .byKey(
            const ValueKey(
              'friend-game-image:https://example.invalid/game.png',
            ),
          )
          .first,
    );
    expect(image.image, isA<MemoryImage>());
    final imageSize = tester.getSize(
      find
          .byKey(
            const ValueKey(
              'friend-game-image:https://example.invalid/game.png',
            ),
          )
          .first,
    );
    expect(imageSize.width, imageSize.height);
    await show('second-friend');
    expect(backend.gameImageRequests, ['Shared game']);
  });
  for (final mobile in [false, true]) {
    testWidgets('favorite cards have no standalone star row (mobile=$mobile)', (
      tester,
    ) async {
      await useLayoutTestViewport(tester, Size(mobile ? 360 : 800, 1000));
      final backend = ToolsBackend(
        friends: [
          const NintendoFriend(
            friendId: 'favorite',
            nickname: 'Favorite',
            note: 'A note',
            isFavorite: true,
            presence: 'ONLINE',
            gameName: 'Splatoon 3',
          ),
          const NintendoFriend(
            friendId: 'regular',
            nickname: 'Regular',
            note: 'A note',
            isFavorite: false,
            presence: 'ONLINE',
            gameName: 'Splatoon 3',
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
      final favorite = find.byKey(const Key('friend-card-open-favorite'));
      final regular = find.byKey(const Key('friend-card-open-regular'));
      expect(
        find.descendant(of: favorite, matching: find.byIcon(Icons.star)),
        findsNothing,
      );
      expect(tester.getSize(favorite).height, tester.getSize(regular).height);
      expect(find.text('特别关注'), findsOneWidget);
      expect(
        tester.getTopLeft(favorite).dy,
        lessThan(tester.getTopLeft(regular).dy),
      );
      expect(
        find.descendant(of: favorite, matching: find.text('Splatoon 3')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: favorite, matching: find.text('A note')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('friend-avatar-open-favorite')));
      await tester.pumpAndSettle();
      expect(find.byType(NintendoFriendDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

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
        tester.getTopLeft(find.text('first id')).dx,
        lessThan(tester.getTopLeft(find.text('second id')).dx),
      );
      expect(
        tester.getTopLeft(find.text('second id')).dy,
        lessThan(tester.getTopLeft(find.text('unstarred')).dy),
      );
      expect(find.text('Hidden friend'), findsNothing);
      await tester.scrollUntilVisible(find.text('离线好友'), 160);
      await tester.tap(find.text('离线好友'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('android-friend-status-hidden')),
        140,
      );
      expect(find.text('状态未公开'), findsNothing);
      expect(
        tester
            .getSemantics(find.byKey(const Key('android-friend-status-hidden')))
            .label,
        contains('状态未公开'),
      );
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
      expect(find.text('特别关注'), findsOneWidget);
      for (final group in ['favorites', 'online', 'offline']) {
        final bubble = tester.widget<DecoratedBox>(
          find.byKey(Key('friend-group-header-bubble-$group')),
        );
        expect(
          (bubble.decoration as BoxDecoration).borderRadius,
          BorderRadius.circular(18),
        );
      }
      expect(find.text('Online friend'), findsOneWidget);
      // Best friends are in their own expanded group, even when offline.
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
  testWidgets(
    'mobile friend group headings use compact text and show their own counts',
    (tester) async {
      final backend = ToolsBackend(
        friends: const [
          NintendoFriend(
            friendId: 'favorite-online',
            nickname: 'Favorite online',
            note: '',
            isFavorite: true,
            presence: 'ONLINE',
          ),
          NintendoFriend(
            friendId: 'ordinary-online',
            nickname: 'Ordinary online',
            note: '',
            isFavorite: false,
            presence: 'ONLINE',
          ),
          NintendoFriend(
            friendId: 'favorite-offline',
            nickname: 'Favorite offline',
            note: '',
            isFavorite: true,
            presence: 'OFFLINE',
          ),
          NintendoFriend(
            friendId: 'ordinary-offline',
            nickname: 'Ordinary offline',
            note: '',
            isFavorite: false,
            presence: 'OFFLINE',
          ),
        ],
      );
      await tester.pumpWidget(
        app(
          NintendoFriendsPage(backend: backend, profile: profile, mobile: true),
        ),
      );
      await tester.pumpAndSettle();

      final favorites = tester.widget<Text>(find.text('特别关注'));
      final online = tester.widget<Text>(find.text('在线好友'));
      final offline = tester.widget<Text>(find.text('离线好友'));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('friend-group-count-favorites')))
            .data,
        '· 2',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('friend-group-count-online')))
            .data,
        '· 1',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('friend-group-count-offline')))
            .data,
        '· 1',
      );
      expect(
        favorites.style?.fontSize,
        lessThan(
          Theme.of(tester.element(find.text('特别关注')))
              .textTheme
              .titleMedium!
              .fontSize!,
        ),
      );
      expect(
        online.style?.fontSize,
        lessThan(
          Theme.of(tester.element(find.text('在线好友')))
              .textTheme
              .titleMedium!
              .fontSize!,
        ),
      );
      expect(
        offline.style?.fontSize,
        lessThan(
          Theme.of(tester.element(find.text('离线好友')))
              .textTheme
              .titleMedium!
              .fontSize!,
        ),
      );
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

class ToolsBackend extends FakeBackend
    implements NintendoAccountToolsBackend, NintendoGameImageBackend {
  ToolsBackend({this.friends, this.friendPlayLog = const []})
    : super(mediaItems: []);
  final List<NintendoFriend>? friends;
  final List<NintendoFriendGame> friendPlayLog;
  final friendPlayLogRequests = <String>[];
  final friendCodeLookups = <String>[];
  final friendRequests = <String>[];
  final avatarRequests = <String>[];
  final gameImageRequests = <String>[];
  final notes = <String>[];
  final noteOperations = <String>[];
  Object? noteError;
  Uint8List avatar = Uint8List(0);
  String lookupFriendId = 'synthetic-lookup';
  Completer<NintendoFriendCodeUser>? lookupGate;
  bool requestAccepted = true;
  bool becameFriends = false;
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
    {
    bool includeSplatoonActivity = false,
    }
  ) async {
    friendAccounts.add(accountId);
    if (failRefresh) throw StateError('network unavailable');
    if (friendGate != null) return friendGate!.future;
    return NintendoFriendsSnapshot(
      friends:
          friends ??
          [
            if (becameFriends && friendRequests.isNotEmpty)
              NintendoFriend(
                friendId: lookupFriendId,
                nickname: 'Lookup preview',
                note: '',
                isFavorite: false,
                presence: 'OFFLINE',
              ),
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
  ) async {
    avatarRequests.add('$accountId:$friendId');
    return avatar;
  }

  @override
  Future<Uint8List> loadNintendoGameImage(
    String accountId,
    String gameName,
    String operationId,
  ) async {
    gameImageRequests.add(gameName);
    return avatar;
  }

  @override
  Future<List<NintendoFriendGame>> loadNintendoFriendPlayLog(
    String accountId,
    String friendId,
    String operationId,
  ) async {
    friendPlayLogRequests.add('$accountId:$friendId');
    return friendPlayLog;
  }

  @override
  Future<NintendoFriendCodeSnapshot> loadNintendoFriendCode(
    String accountId,
    String operationId,
  ) async =>
      const NintendoFriendCodeSnapshot(friendCode: '1111-2222-3333', url: '');

  @override
  Future<NintendoFriendCodeUser> lookupNintendoFriendCode(
    String accountId,
    String friendCode,
    String operationId,
  ) async {
    friendCodeLookups.add('$accountId:$friendCode');
    if (lookupGate != null) return lookupGate!.future;
    return NintendoFriendCodeUser(
      friendId: lookupFriendId,
      nickname: 'Lookup preview',
    );
  }

  @override
  Future<NintendoFriendRequestResult> sendNintendoFriendRequest(
    String accountId,
    String friendId,
    String operationId,
  ) async {
    friendRequests.add('$accountId:$friendId');
    return NintendoFriendRequestResult(
      friendId: friendId,
      accepted: requestAccepted,
    );
  }

  @override
  Future<void> updateNintendoFriendNote(
    String accountId,
    String friendId,
    String note,
    String operationId,
  ) async {
    noteOperations.add(operationId);
    final error = noteError;
    if (error != null) throw error;
    notes.add('$accountId:$friendId:$note');
  }

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
