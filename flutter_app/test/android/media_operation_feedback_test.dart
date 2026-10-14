import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/state/media_edit_controller.dart';
import 'package:squid_album/src/ui/android/android_operation_progress.dart';
import 'package:squid_album/src/ui/android/android_video_editor.dart';

class ProgressBackend implements AppBackend, OperationProgressBackend {
  final updates = StreamController<OperationProgressValue>.broadcast(
    sync: true,
  );
  @override
  Stream<OperationProgressValue> get operationProgress => updates.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected backend call: ${invocation.memberName}',
  );
}

void main() {
  testWidgets(
    'trim timestamps remain visible at large text with sub-second precision',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 296,
                  child: AndroidTrimTimestamps(
                    start: Duration(milliseconds: 300),
                    end: Duration(milliseconds: 2300),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Start 0:00.300'), findsOneWidget);
      expect(find.text('End 0:02.300'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'media editor exposes encoding statistics only during its own task',
    () async {
      final backend = ProgressBackend();
      final editor = MediaEditController(backend);
      final gate = Completer<void>();
      final work = editor.execute(() => gate.future);
      backend.updates.add(
        const OperationProgressValue(
          operationId: 'import',
          kind: 'custom_import',
          phase: 'importing',
          fraction: .8,
        ),
      );
      expect(editor.progress.value?.value, isNull);
      backend.updates.add(
        const OperationProgressValue(
          operationId: 'trim',
          kind: 'video_trim',
          phase: 'encoding',
          fraction: .3,
        ),
      );
      expect(editor.progress.value?.value, .3);
      gate.complete();
      await work;
      backend.updates.add(
        const OperationProgressValue(
          operationId: 'unrelated',
          kind: 'video_trim',
          phase: 'encoding',
          fraction: .9,
        ),
      );
      expect(editor.progress.value?.value, .3);
      await editor.dispose();
      await backend.updates.close();
    },
  );
  testWidgets(
    'encoding progress is determinate; ingestion has no invented percentage',
    (tester) async {
      Future<void> show(String phase, double? fraction) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            home: Scaffold(
              body: AndroidOperationProgress(
                progress: OperationProgressValue(
                  operationId: 'trim',
                  kind: 'video_trim',
                  phase: phase,
                  fraction: fraction,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await show('encoding', .4);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .4,
      );
      await show('ingesting', null);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
      expect(find.text('正在校验并保存'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
