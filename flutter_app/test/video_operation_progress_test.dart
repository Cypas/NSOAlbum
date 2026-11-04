import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/video_operation_progress.dart';

void main() {
  test(
    'encoding time advances progress but only committed output completes it',
    () {
      final operation = VideoOperationProgress(
        operationId: 'trim-1',
        kind: 'video_trim',
        duration: const Duration(seconds: 10),
      );
      expect(operation.encode(2500).value, .25);
      expect(operation.encode(10000).value, lessThan(1));
      expect(operation.ingesting().value, isNull);
      expect(operation.complete().value, 1);
      expect(operation.complete().status, 'completed');
    },
  );
  test('unknown encoding duration stays indeterminate instead of inventing a total', () {
    final operation = VideoOperationProgress(
      operationId: 'merge-1',
      kind: 'video_merge',
    );
    expect(operation.encode(3000).value, isNull);
    expect(operation.failed().status, 'failed');
    expect(operation.failed().value, isNull);
  });
}
