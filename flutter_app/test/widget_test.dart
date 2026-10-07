import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';

void main() {
  testWidgets('shows a useful startup failure', (tester) async {
    await tester.pumpWidget(
      const SquidAlbumApp(startupError: 'native library unavailable'),
    );

    expect(find.text('Failed to initialize Fresh Album core'), findsOneWidget);
    expect(find.text('native library unavailable'), findsOneWidget);
  });
}
