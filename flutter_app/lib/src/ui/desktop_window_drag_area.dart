import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

class DesktopWindowDragArea extends StatelessWidget {
  const DesktopWindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Platform.isWindows || Platform.isMacOS
      ? DragToMoveArea(child: child)
      : child;
}
