import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/video_runtime.dart';

void main() {
  test('Android skips idle media-player prewarm', () {
    expect(
      shouldPrewarmVideoRuntime(
        isAndroid: true,
        ciSmoke: false,
        isTest: false,
        disabled: false,
        safeMode: false,
      ),
      isFalse,
    );
  });

  test('desktop keeps media-player prewarm when startup allows it', () {
    expect(
      shouldPrewarmVideoRuntime(
        isAndroid: false,
        ciSmoke: false,
        isTest: false,
        disabled: false,
        safeMode: false,
      ),
      isTrue,
    );
  });
}
