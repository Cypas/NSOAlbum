import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/startup/desktop_instance_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  test(
    'secondary requests native message-loop exit, not guarded primary close',
    () async {
      final requests = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        requests.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await dismissSecondaryDesktopWindow();
      expect(requests, ['ensureInitialized', 'destroy']);
    },
  );
}
