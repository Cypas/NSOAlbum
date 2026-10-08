import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../rust/models.dart';
import '../rust/settings.dart';
import '../ui/font_families.dart';

class SettingsController extends ChangeNotifier {
  SettingsController(this._backend) : value = _backend.settings;

  final AppBackend _backend;
  AppSettings value;
  bool saving = false;
  Object? error;

  String get logFilePath => _backend.logFilePath;

  Future<void> openLogFile() => _backend.openLogFile();

  Future<void> logError(
    String message,
    Object error, [
    StackTrace? stackTrace,
  ]) => _backend.logError(message, error, stackTrace);

  Future<void> save(AppSettings next) async {
    saving = true;
    error = null;
    notifyListeners();
    try {
      final fontReport = listEquals(value.customFontPaths, next.customFontPaths)
          ? null
          : await prepareCustomFontFamilies(next.customFontPaths);
      await _backend.saveSettings(next);
      value = next;
      if (fontReport != null) {
        applyCustomFontReport(fontReport, language: next.language);
      } else {
        selectAppFontLanguage(next.language);
      }
    } catch (exception, stackTrace) {
      error = exception;
      await _backend.logError('Failed to save settings', exception, stackTrace);
      rethrow;
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<LibraryRelocationResult> relocateMediaLibrary(AppSettings next) async {
    saving = true;
    error = null;
    notifyListeners();
    try {
      final result = await _backend.relocateMediaLibrary(next);
      value = next;
      return result;
    } catch (exception, stackTrace) {
      error = exception;
      await _backend.logError(
        'Failed to relocate media library',
        exception,
        stackTrace,
      );
      rethrow;
    } finally {
      saving = false;
      notifyListeners();
    }
  }
}
