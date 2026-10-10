@Tags(['platform-macos'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:squid_album/main.dart';
import 'package:squid_album/src/backend/storage_paths.dart';
import 'package:squid_album/src/platform/windows_ime_context.dart';
import 'package:squid_album/src/startup/startup_options.dart';
import 'package:squid_album/src/ui/font_families.dart';
import 'package:squid_album/src/ui/home_shell.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final macosOnly = Platform.isMacOS ? false : 'Requires native macOS host';

  group('[macOS]', () {
    testWidgets(
      'macOS frame preserves content without Windows custom title bar',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: DesktopWindowFrame(
              title: 'NSOAlbum',
              child: Scaffold(body: Text('Library', key: Key('macos-content'))),
            ),
          ),
        );

        expect(find.byKey(const Key('macos-content')), findsOneWidget);
        expect(find.byType(DesktopTitleBar), findsNothing);
        expect(find.byKey(const Key('desktop-titlebar')), findsNothing);
        expect(
          find.byKey(const Key('desktop-titlebar-minimize')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'macOS settings omit Windows fonts and installer updater controls',
      (tester) async {
        await loadCustomFontFamilies(const []);
        await tester.binding.setSurfaceSize(const Size(1200, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
        await tester.pumpAndSettle();
        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();

        expect(find.byType(SettingsPage), findsOneWidget);
        expect(find.byKey(const Key('font-management-card')), findsNothing);
        expect(find.byKey(const Key('choose-custom-fonts')), findsNothing);
        final settingsScroll = find.byType(CustomScrollView);
        await tester.drag(settingsScroll, const Offset(0, -1600));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('about-card')), findsOneWidget);
        expect(find.byKey(const Key('check-app-updates')), findsNothing);
        expect(find.byKey(const Key('font-management-card')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('normal macOS startup never sends Windows IME focus messages', (
      tester,
    ) async {
      const channel = MethodChannel('io.squidalbum/ime_context');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      WindowsImeContextCoordinator.instance.resetForTesting();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        WindowsImeContextCoordinator.instance.resetForTesting();
        messenger.setMockMethodCallHandler(channel, null);
      });
      final options = StartupOptions.parse(const []);
      expect(options.safeMode, isFalse);
      WindowsImeContextCoordinator.instance.start(
        enabled: !options.safeMode && !options.disableIme,
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: TextField(key: Key('macos-editor'))),
        ),
      );
      await tester.tap(find.byKey(const Key('macos-editor')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(calls, isEmpty);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
    });

    test('macOS library paths use native support directories and keep legacy roots', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'nsoalbum_macos_paths_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final support = p.join(temporary.path, 'NSOAlbum');
      final legacy = p.join(
        temporary.path,
        'Fresh Album',
        libraryDirectoryName,
      );
      expect(
        defaultLibraryPathForPlatform(
          supportDirectory: support,
          isWindows: Platform.isWindows,
          picturesDirectory: p.join(temporary.path, 'Pictures'),
        ),
        p.join(support, 'media'),
      );
      expect(
        await resolveApplicationRoot(
          support,
          isValidLibraryRoot: (candidate) async => candidate == legacy,
        ),
        legacy,
      );
      expect(
        await resolveApplicationRoot(
          support,
          isValidLibraryRoot: (_) async => false,
        ),
        p.join(support, libraryDirectoryName),
      );
    });
  }, skip: macosOnly);
}
