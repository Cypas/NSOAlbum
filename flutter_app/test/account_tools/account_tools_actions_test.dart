import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/account_tools/account_tools_expander.dart';

import 'account_tools_pages_test.dart' show app, ToolsBackend, profile;

void main() {
  testWidgets(
    'desktop expanding tools never selects the account and friends bind the clicked account',
    (tester) async {
      var selections = 0;
      final backend = ToolsBackend();
      await tester.pumpWidget(
        app(
          Scaffold(
            body: AccountToolsExpander(
              backend: backend,
              profile: profile,
              header: TextButton(
                onPressed: () => selections++,
                child: const Text('Select B'),
              ),
            ),
          ),
        ),
      );
      expect(find.text('好友列表'), findsNothing);
      await tester.tap(find.byKey(const Key('account-tools-expand-clicked-b')));
      await tester.pumpAndSettle();
      expect(selections, 0);
      expect(find.text('好友列表'), findsOneWidget);
      expect(find.text('鱿鱼圈'), findsOneWidget);
      expect(find.text('观星'), findsOneWidget);
      await tester.tap(find.text('好友列表'));
      await tester.pumpAndSettle();
      expect(backend.friendAccounts, ['clicked-b']);
      expect(find.text('Online friend'), findsOneWidget);
      expect(selections, 0);
    },
  );
}
