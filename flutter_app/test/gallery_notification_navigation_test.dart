import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/platform/gallery_notification_navigation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('io.github.cypas.nsoalbum/notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('opens gallery only for the payload-free gallery action', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final navigation = GalleryNotificationNavigation(channel: channel);
    var opened = 0;
    navigation.addListener(() => opened++);

    await navigation.handleForTest(const MethodCall('syncCompleted'));
    await navigation.handleForTest(
      const MethodCall('openGallery', {'path': '/private/media.jpg'}),
    );
    expect(opened, 0);

    await navigation.handleForTest(const MethodCall('openGallery'));
    expect(opened, 1);
    navigation.dispose();
  });

  testWidgets('notification navigation selects library and refreshes it', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final navigation = GalleryNotificationNavigation(channel: channel);
    var selected = 1;
    var reloads = 0;
    navigation.addListener(() {
      selected = 0;
      reloads++;
    });
    await navigation.handleForTest(const MethodCall('openGallery'));

    expect(selected, 0);
    expect(reloads, 1);
    navigation.dispose();
  });
}
