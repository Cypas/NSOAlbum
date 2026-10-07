import 'package:flutter/widgets.dart';

/// Mounts only the currently visible top-level page.
///
/// Keeping every desktop page alive in an [IndexedStack] also keeps all of
/// their media thumbnails, platform views and async listeners alive. On
/// Windows this can grow into a large retained render tree and has triggered
/// native Flutter engine crashes while changing pages. Top-level page state is
/// intentionally recreated when switching pages; persistent settings and
/// media state live in the backend/controllers.
class ActivePageHost extends StatelessWidget {
  const ActivePageHost({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final boundedIndex = index.clamp(0, children.length - 1);
    return KeyedSubtree(
      key: ValueKey('active-page-$boundedIndex'),
      child: children[boundedIndex],
    );
  }
}
