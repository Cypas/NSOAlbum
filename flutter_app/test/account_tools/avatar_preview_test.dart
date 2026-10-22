import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/account_tools/avatar_preview.dart';

Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final nativeSave =
      Platform.isAndroid &&
      binding is LiveTestWidgetsFlutterBinding &&
      const bool.fromEnvironment('NSOALBUM_AVATAR_SAVE_DEVICE_QA');
  if (nativeSave) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (binding.platformDispatcher.views.first.physicalSize.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Android native viewport did not initialize.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  for (final result in ['saved', 'cancelled', 'failed']) {
    testWidgets('avatar save $result keeps the preview and original bytes', (
      tester,
    ) async {
      final previous = FilePickerPlatform.instance;
      final picker = _SavePicker(result);
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showNintendoAvatarPreview(
                  context,
                  bytes: bytes,
                  nickname: 'Synthetic avatar',
                ),
                child: const Text('Open avatar'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open avatar'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('app-image-viewer-save')));
      await tester.pumpAndSettle();
      expect(picker.savedBytes, bytes);
      expect(picker.mime, 'image/png');
      expect(picker.name, 'nintendo_avatar.png');
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('app-image-viewer-close')));
      await tester.pumpAndSettle();
      expect(find.text('Open avatar'), findsOneWidget);
    });
  }

  group(
    'Android native avatar save',
    () {
      testWidgets(
        'synthetic avatar saves through the real Android document picker',
        (tester) async {
          final previous = FilePickerPlatform.instance;
          final picker = _ObservedNativeSavePicker(previous);
          FilePickerPlatform.instance = picker;
          addTearDown(() => FilePickerPlatform.instance = previous);
          final bytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          );
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showNintendoAvatarPreview(
                      context,
                      bytes: bytes,
                      nickname: 'Synthetic avatar',
                    ),
                    child: const Text('Open synthetic avatar'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open synthetic avatar'));
          await tester.pumpAndSettle();
          expect(find.byType(InteractiveViewer), findsOneWidget);
          await tester.tap(find.byKey(const Key('app-image-viewer-save')));
          final saveDeadline = DateTime.now().add(const Duration(minutes: 3));
          while (!picker.completed.isCompleted) {
            if (DateTime.now().isAfter(saveDeadline)) {
              throw TimeoutException(
                'The synthetic avatar document save did not complete.',
              );
            }
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          final result = await picker.completed.future;
          expect(
            result,
            isNotNull,
            reason: 'A cancelled picker is not a save.',
          );
          expect(picker.savedBytes, bytes);
          expect(picker.mime, 'image/png');
          expect(picker.name, 'nintendo_avatar.png');
          await tester.pumpAndSettle();
          expect(find.byType(InteractiveViewer), findsOneWidget);
          await tester.tap(find.byKey(const Key('app-image-viewer-close')));
          await tester.pumpAndSettle();
          expect(find.text('Open synthetic avatar'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        tags: const ['platform-android', 'native-android'],
        timeout: const Timeout(Duration(minutes: 4)),
      );
    },
    skip: nativeSave
        ? false
        : 'Run this test on Android with a Live binding and '
              'NSOALBUM_AVATAR_SAVE_DEVICE_QA=true; only a synthetic PNG is saved.',
  );
}

/// Observes the plugin result while preserving the real native document picker.
/// No account, Rust core, personal image, or library is opened by this test.
class _ObservedNativeSavePicker extends FilePickerPlatform {
  _ObservedNativeSavePicker(this.delegate);

  final FilePickerPlatform delegate;
  final completed = Completer<Uri?>();
  Uint8List? savedBytes;
  String? mime;
  String? name;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    savedBytes = bytes;
    mime = mimeType;
    name = fileName;
    try {
      final result = await delegate.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        onFileSaving: onFileSaving,
        windowsOptions: windowsOptions,
        linuxOptions: linuxOptions,
        webOptions: webOptions,
      );
      completed.complete(result);
      return result;
    } catch (_) {
      completed.complete(null);
      rethrow;
    }
  }
}

class _SavePicker extends FilePickerPlatform {
  _SavePicker(this.result);
  final String result;
  Uint8List? savedBytes;
  String? mime;
  String? name;
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    savedBytes = bytes;
    mime = mimeType;
    name = fileName;
    if (result == 'failed') throw StateError('synthetic picker failure');
    return result == 'saved'
        ? Uri.parse('content://synthetic/avatar.png')
        : null;
  }
}
