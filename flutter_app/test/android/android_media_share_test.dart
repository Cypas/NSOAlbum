@Tags(['platform-android'])
library;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/platform/android_media_share.dart';
import 'package:squid_album/src/rust/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.cypas.nsoalbum/share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'shares media files through content URI bridge without exposing a URI',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      await AndroidMediaShare().share([
        '/data/user/0/io.github.cypas.nsoalbum/files/NSOAlbum/media/a.jpg',
      ]);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'shareMedia');
      expect(calls.single.arguments, {
        'paths': [
          '/data/user/0/io.github.cypas.nsoalbum/files/NSOAlbum/media/a.jpg',
        ],
      });
    },
  );

  test(
    'rejects an empty media selection before invoking native code',
    () async {
      var invoked = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        invoked = true;
        return null;
      });

      expect(() => AndroidMediaShare().share(const []), throwsArgumentError);
      expect(invoked, isFalse);
    },
  );

  testWidgets('media share opens the system chooser directly', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAndroidMediaShareSheet(context, [
                _media(),
              ], share: AndroidMediaShare()),
              child: const Text('Share'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(find.text('聊天应用'), findsNothing);
    expect(find.text('更多应用'), findsNothing);
    expect(calls.single.method, 'shareMedia');
    expect((calls.single.arguments as Map).containsKey('packageName'), isFalse);
  });
}

MediaAsset _media() => const MediaAsset(
  id: 1,
  sha256: 'sha',
  originalName: 'image.jpg',
  storagePath: '/private/image.jpg',
  kind: MediaKind.image,
  gameName: 'Game',
  favorite: false,
  tags: [],
);
