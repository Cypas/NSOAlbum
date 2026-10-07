import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/startup/startup_options.dart';

void main() {
  test('full safe mode disables desktop, sync, video, and IME startup', () {
    final options = StartupOptions.parse(const ['--safe-mode']);

    expect(options.safeMode, isTrue);
    expect(options.disableDesktopLifecycle, isTrue);
    expect(options.disableAutomaticSync, isTrue);
    expect(options.disableVideoThumbnails, isTrue);
    expect(options.disableMtpDetection, isTrue);
    expect(options.disableIme, isFalse);
  });

  test('component safe modes only disable the requested component', () {
    final video = StartupOptions.parse(const ['--safe-mode=no-video']);
    final ime = StartupOptions.parse(const ['--safe-mode=no-ime']);

    expect(video.disableVideoThumbnails, isTrue);
    expect(video.disableAutomaticSync, isFalse);
    expect(video.disableIme, isFalse);
    expect(video.disableMtpDetection, isFalse);
    expect(ime.disableIme, isTrue);
    expect(ime.disableVideoThumbnails, isFalse);
  });

  test('software mode only requests the software renderer', () {
    final options = StartupOptions.parse(const ['--safe-mode=software']);

    expect(options.softwareRendering, isTrue);
    expect(options.safeMode, isFalse);
    expect(options.disableVideoThumbnails, isFalse);
  });
}
