import 'package:flutter/material.dart';

/// A single account header tap target with a decorative expansion indicator.
class AndroidAccountExpander extends StatefulWidget {
  const AndroidAccountExpander({
    super.key,
    required this.identity,
    required this.details,
    required this.children,
  });

  final Widget identity;
  final Widget details;
  final List<Widget> children;

  @override
  State<AndroidAccountExpander> createState() => _AndroidAccountExpanderState();
}

class _AndroidAccountExpanderState extends State<AndroidAccountExpander> {
  bool _expanded = false;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_restored) {
      _expanded = PageStorage.maybeOf(context)?.readState(context) == true;
      _restored = true;
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MergeSemantics(
        child: Semantics(
          button: true,
          expanded: _expanded,
          child: InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: DefaultTextStyle.merge(
                  style: Theme.of(context).textTheme.bodyMedium,
                  child: Stack(
                    children: [
                      Padding(
                        // Reserve only the decorative icon and a small gap.
                        padding: const EdgeInsetsDirectional.only(end: 22),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            widget.identity,
                            const SizedBox(width: 8),
                            Expanded(child: widget.details),
                          ],
                        ),
                      ),
                      PositionedDirectional(
                        end: 0,
                        top: 0,
                        bottom: 0,
                        child: ExcludeSemantics(
                          child: Center(
                            child: AnimatedRotation(
                              turns: _expanded ? .5 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: const Icon(Icons.expand_more, size: 18),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: _expanded
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              )
            : const SizedBox(width: double.infinity),
      ),
    ],
  );
}
