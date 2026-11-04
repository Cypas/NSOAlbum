import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/gallery_drag_loading.dart';
import 'package:squid_album/src/ui/gallery_perf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final stopWhileMoving in [false, true]) {
    test(
      'old resume tickets are rejected across captures (moving=$stopWhileMoving)',
      () {
        final perf = GalleryPerf(enabled: true)..start();
        perf.loadingPhase(GalleryDragPhase.moving);
        final oldTicket = perf.previewTicket(thumbActive: true);
        if (!stopWhileMoving) perf.loadingPhase(GalleryDragPhase.idle);
        perf.stop();
        perf.start();
        perf.loadingPhase(GalleryDragPhase.moving);
        final currentTicket = perf.previewTicket(thumbActive: true);
        perf.loadingPhase(GalleryDragPhase.idle);
        perf.previewPresented(oldTicket);
        expect((perf.snapshot()['timings'] as Map)['dragImageLatency'], isNull);
        perf.previewPresented(currentTicket);
        expect(
          ((perf.snapshot()['timings'] as Map)['dragImageLatency']
              as Map)['count'],
          1,
        );
        perf.stop();
      },
    );
  }
  test(
    'resume latency accepts only the matching thumb-resume request generation',
    () {
      final perf = GalleryPerf(enabled: true)..start();
      perf.loadingPhase(GalleryDragPhase.moving);
      final firstTicket = perf.previewTicket(thumbActive: true);
      perf.loadingPhase(GalleryDragPhase.idle);
      perf.previewPresented(firstTicket);
      expect(
        ((perf.snapshot()['timings'] as Map)['dragImageLatency']
            as Map)['count'],
        1,
      );
      expect(perf.previewTicket(), isNull);
      perf.previewPresented(null);
      perf.loadingPhase(GalleryDragPhase.moving);
      final secondTicket = perf.previewTicket(thumbActive: true);
      perf.loadingPhase(GalleryDragPhase.idle);
      perf.previewPresented(firstTicket);
      expect(
        ((perf.snapshot()['timings'] as Map)['dragImageLatency']
            as Map)['count'],
        1,
      );
      perf.previewPresented(secondTicket);
      expect(
        ((perf.snapshot()['timings'] as Map)['dragImageLatency']
            as Map)['count'],
        2,
      );
      perf.stop();
    },
  );
}
