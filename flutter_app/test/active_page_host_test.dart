import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/active_page_host.dart';

void main() {
  testWidgets('fades between selected pages without retaining old page', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              FilledButton(
                onPressed: () => setState(() => selected = 1),
                child: const Text('switch'),
              ),
              Expanded(
                child: _SelectedPageHost(
                  getIndex: () => selected,
                  children: [
                    _BuildCounterPage(counter: _Counter.first),
                    _BuildCounterPage(counter: _Counter.second),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);
    expect(find.byType(AnimatedSwitcher), findsOneWidget);

    await tester.tap(find.text('switch'));
    await tester.pump();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
  });
}

class _SelectedPageHost extends StatelessWidget {
  const _SelectedPageHost({required this.getIndex, required this.children});

  final int Function() getIndex;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      ActivePageHost(index: getIndex(), children: children);
}

enum _Counter { first, second }

class _BuildCounterPage extends StatelessWidget {
  const _BuildCounterPage({required this.counter});

  final _Counter counter;

  @override
  Widget build(BuildContext context) =>
      Text(counter == _Counter.first ? 'first' : 'second');
}
