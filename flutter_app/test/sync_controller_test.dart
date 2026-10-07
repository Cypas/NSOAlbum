import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/state/sync_controller.dart';

void main() {
  test('rate limited sync errors request a one minute automatic retry', () {
    expect(
      automaticSyncRetryDelayForError(
        StateError('rate limited: retry after 900 seconds'),
      ),
      const Duration(minutes: 1),
    );
  });

  test('ordinary sync errors do not override the configured schedule', () {
    expect(
      automaticSyncRetryDelayForError(StateError('network unavailable')),
      isNull,
    );
  });
}
