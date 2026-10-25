import 'package:flutter/services.dart';

class WindowsSystemFont {
  const WindowsSystemFont({required this.name, required this.path});

  final String name;
  final String path;

  factory WindowsSystemFont.fromMap(Map<Object?, Object?> value) =>
      WindowsSystemFont(
        name: value['name'] as String? ?? 'System font',
        path: value['path'] as String? ?? '',
      );
}

class WindowsSystemFonts {
  const WindowsSystemFonts();

  static const _channel = MethodChannel(
    'io.github.cypas.nsoalbum/system_fonts',
  );

  Future<List<WindowsSystemFont>> list() async {
    final raw =
        await _channel.invokeMethod<List<Object?>>('list') ?? const <Object?>[];
    final fonts = <WindowsSystemFont>[];
    for (final item in raw) {
      if (item is Map<Object?, Object?>) {
        final font = WindowsSystemFont.fromMap(item);
        if (font.path.trim().isNotEmpty) fonts.add(font);
      }
    }
    fonts.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return fonts;
  }
}
