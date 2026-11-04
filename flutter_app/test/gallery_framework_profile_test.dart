import 'package:flutter_test/flutter_test.dart';

import '../tool/gallery_framework_profile.dart';
import '../tool/gallery_framework_report.dart';

void main() {
  test(
    'framework flags restore original values even after partial failure',
    () async {
      final values = <String, bool>{
        'ext.flutter.profileWidgetBuilds': false,
        'ext.flutter.profileRenderObjectLayouts': true,
        'ext.flutter.profileRenderObjectPaints': false,
      };
      var rejectPaint = true;
      final scope = GalleryFrameworkProfile((method, arguments) async {
        if (arguments['enabled'] case final String enabled) {
          if (method.endsWith('Paints') && enabled == 'true' && rejectPaint) {
            rejectPaint = false;
            throw StateError('private-response');
          }
          values[method] = enabled == 'true';
        }
        return {'enabled': '${values[method]}'};
      });
      await expectLater(scope.enable(values.keys.toSet()), throwsStateError);
      await scope.restore();
      expect(values, {
        'ext.flutter.profileWidgetBuilds': false,
        'ext.flutter.profileRenderObjectLayouts': true,
        'ext.flutter.profileRenderObjectPaints': false,
      });
      expect(scope.summary['restored'], true);
      expect(scope.summary.toString(), isNot(contains('private')));
    },
  );

  test('completed diagnostic restores all flags without inventing unsupported ones', () async {
    final values = {'ext.flutter.profileWidgetBuilds': false};
    final scope = GalleryFrameworkProfile((method, arguments) async {
      if (!values.containsKey(method)) throw StateError('not advertised');
      if (arguments['enabled'] case final String enabled) {
        values[method] = enabled == 'true';
      }
      return {'enabled': '${values[method]}'};
    });
    await scope.enable(values.keys.toSet());
    expect(values.values.single, true);
    await scope.restore();
    expect(values.values.single, false);
    expect(scope.summary['enabledCount'], 1);
    expect(scope.summary['restored'], true);
  });

  test('component spans use nearest framework phase and discard arbitrary labels and args', () {
    final report = summarizeFrameworkComponents([
      {'ph': 'E', 'ts': 110, 'pid': 1, 'tid': 1},
      {'name': 'LAYOUT (root)', 'ph': 'B', 'ts': 0, 'pid': 1, 'tid': 1},
      {'name': 'BUILD', 'ph': 'B', 'ts': 10, 'pid': 1, 'tid': 1},
      {
        'name': 'IconButton',
        'ph': 'B',
        'ts': 20,
        'pid': 1,
        'tid': 1,
        'args': {'path': 'private', 'key': 'private-account'},
      },
      {'name': 'Text', 'ph': 'B', 'ts': 30, 'pid': 1, 'tid': 1},
      {'ph': 'E', 'ts': 40, 'pid': 1, 'tid': 1},
      {'ph': 'E', 'ts': 60, 'pid': 1, 'tid': 1},
      {'ph': 'E', 'ts': 70, 'pid': 1, 'tid': 1},
      {
        'name': 'RenderFlex',
        'ph': 'X',
        'ts': 70,
        'dur': 25,
        'pid': 1,
        'tid': 1,
      },
      {
        'name': 'PrivateAccountWidget',
        'ph': 'X',
        'ts': 70,
        'dur': 25,
        'pid': 1,
        'tid': 1,
      },
    ]);
    final rows = report['components'] as List;
    final icon = rows.singleWhere((row) => row['type'] == 'IconButton') as Map;
    final text = rows.singleWhere((row) => row['type'] == 'Text') as Map;
    final flex = rows.singleWhere((row) => row['type'] == 'RenderFlex') as Map;
    expect(icon['phase'], 'build');
    expect(icon['totalMicros'], 40);
    expect(text['totalMicros'], 10);
    expect(flex['phase'], 'layout');
    expect(flex['totalMicros'], 25);
    expect(report['basis'], 'inclusive_nested_not_additive');
    expect(report.toString(), isNot(contains('private')));
    expect(report.toString(), isNot(contains('PrivateAccount')));
  });
}
