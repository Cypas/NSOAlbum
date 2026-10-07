import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/active_page_host.dart';

void main() {
  testWidgets('only the selected page is mounted', (tester) async {
    var firstBuilds = 0;
    var secondBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              FilledButton(
                onPressed: () => setState(() {}),
                child: const Text('noop'),
              ),
              const Expanded(
                child: ActivePageHost(
                  index: 0,
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

    // Rebuild the host with the other index and verify that the first page is
    // removed instead of remaining alive in an IndexedStack.
    await tester.pumpWidget(
      const MaterialApp(
        home: ActivePageHost(
          index: 1,
          children: [
            _BuildCounterPage(counter: _Counter.first),
            _BuildCounterPage(counter: _Counter.second),
          ],
        ),
      ),
    );

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    expect(firstBuilds + secondBuilds, 0);
  });
}

enum _Counter { first, second }

class _BuildCounterPage extends StatelessWidget {
  const _BuildCounterPage({required this.counter});

  final _Counter counter;

  @override
  Widget build(BuildContext context) =>
      Text(counter == _Counter.first ? 'first' : 'second');
}
