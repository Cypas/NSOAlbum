import 'app_backend.dart';

/// Encoding statistics never imply that validation and ingestion have finished.
class VideoOperationProgress {
  VideoOperationProgress({
    required this.operationId,
    required this.kind,
    this.duration,
  });
  final String operationId;
  final String kind;
  final Duration? duration;

  OperationProgressValue encode(int milliseconds) => OperationProgressValue(
    operationId: operationId,
    kind: kind,
    phase: 'encoding',
    fraction: duration != null && duration!.inMilliseconds > 0
        ? (milliseconds / duration!.inMilliseconds).clamp(0, .99)
        : null,
  );
  OperationProgressValue ingesting() => OperationProgressValue(
    operationId: operationId,
    kind: kind,
    phase: 'ingesting',
  );
  OperationProgressValue complete() => OperationProgressValue(
    operationId: operationId,
    kind: kind,
    phase: 'finished',
    status: 'completed',
    fraction: 1,
  );
  OperationProgressValue failed() => OperationProgressValue(
    operationId: operationId,
    kind: kind,
    phase: 'finished',
    status: 'failed',
  );
}
