import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/ui/nxapi_disclosure_card.dart';

void main() {
  Future<void> showCard(WidgetTester tester, String language) =>
      tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const Scaffold(
            body: SingleChildScrollView(child: NxapiDisclosureCard()),
          ),
        ),
      );

  testWidgets(
    'Chinese disclosure is selectable and has a separate tinted card',
    (tester) async {
      await showCard(tester, 'zh');
      expect(find.text('NXAPI 第三方登录说明'), findsOneWidget);
      expect(find.textContaining('id_token并不会泄露您的账户信息'), findsOneWidget);
      expect(find.byType(SelectableText), findsNWidgets(2));
      final card = tester.widget<Card>(
        find.byKey(const Key('nxapi-login-disclosure')),
      );
      expect(card.elevation, greaterThan(0));
      expect(card.shadowColor, isNotNull);
      expect(card.color, isNotNull);
    },
  );

  testWidgets('English disclosure translates the login and risk explanation', (
    tester,
  ) async {
    await showCard(tester, 'en');
    expect(find.text('Third-party NXAPI sign-in notice'), findsOneWidget);
    expect(find.textContaining('sent to a third-party API'), findsOneWidget);
    expect(
      find.textContaining('cannot guarantee account security'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'id_token does not disclose your account information',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('encrypted and stored locally'), findsOneWidget);
    expect(find.text('NXAPI 第三方登录说明'), findsNothing);
  });

  testWidgets('provider link opens the project in the system browser', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await showCard(tester, 'zh');
    await tester.tap(find.byKey(const Key('nxapi-provider-link')));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'launch');
    final arguments = calls.single.arguments as Map;
    expect(
      arguments['url'],
      'https://github.com/samuelthomas2774/nxapi-znca-api',
    );
    expect(arguments['useWebView'], false);
  });

  testWidgets('a failed browser launch shows a readable error', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await showCard(tester, 'en');
    await tester.tap(find.byKey(const Key('nxapi-provider-link')));
    await tester.pumpAndSettle();
    expect(find.text('Unable to open the link.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disclosure fits a narrow window without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final language in ['zh', 'en']) {
      await showCard(tester, language);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('nxapi-provider-link')));
    }
  });

  testWidgets('a missing browser handler does not interrupt sign-in', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'no-browser');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await showCard(tester, 'zh');
    await tester.tap(find.byKey(const Key('nxapi-provider-link')));
    await tester.pumpAndSettle();
    expect(find.text('无法打开链接。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('nxapi-login-disclosure')), findsOneWidget);
  });
}
