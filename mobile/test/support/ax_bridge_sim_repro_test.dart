// Replays framework semantics updates through the desktop engines' AXTree
// checks (see ax_bridge_sim.dart) for the widget shapes the client uses, to
// find which of them the macOS accessibility bridge rejects.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_bridge_sim.dart';

void main() {
  final binding = AxBridgeSimBinding.ensureInitialized();

  setUp(() {
    binding.sim.reset();
    binding.labels.clear();
  });

  String describe(AxBridgeSim sim) => sim.failures
      .map((f) {
        final ids = RegExp(
          r'\d+',
        ).allMatches(f.error).map((m) => int.parse(m.group(0)!)).toSet();
        final named = ids
            .map((id) => '$id=${binding.labels[id] ?? '?'}')
            .join('; ');
        return '$f\n  nodes: $named';
      })
      .join('\n');

  testWidgets('plain scaffold with a list produces no rejected update', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('t')),
          body: ListView(
            children: [
              for (var i = 0; i < 30; i++) ListTile(title: Text('$i')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(binding.sim.failures, isEmpty, reason: describe(binding.sim));
    handle.dispose();
  });

  testWidgets('known engine bug: hovering between tooltips in a ListView', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: const [
              Row(
                children: [
                  Tooltip(message: 'one', child: Icon(Icons.add)),
                  Tooltip(message: 'two', child: Icon(Icons.remove)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.add)));
    await tester.pump(const Duration(seconds: 2));
    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.remove)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    // flutter/flutter#182444 (Flutter 3.41): the engine rejects this update.
    // The harness must see what the engine sees; if this expectation starts
    // failing after a Flutter upgrade, the framework bug is fixed and this
    // test can go.
    expect(
      binding.sim.transitions,
      contains(matches(RegExp(r'will not be in the tree'))),
    );
    handle.dispose();
  });

  testWidgets('OverlayPortal shown one frame after first build', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final controller = OverlayPortalController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < 10; i++) ListTile(title: Text('m$i')),
                  ],
                ),
              ),
              OverlayPortal(
                controller: controller,
                overlayChildBuilder: (context) => const Positioned(
                  left: 0,
                  bottom: 80,
                  child: Material(child: Text('suggestions')),
                ),
                child: const TextField(),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final before = binding.sim.failures.length;
    controller.show();
    await tester.pump();
    await tester.pump();
    controller.hide();
    await tester.pump();
    await tester.pump();
    expect(binding.sim.failures.length, before, reason: describe(binding.sim));
    handle.dispose();
  });

  testWidgets('opaque route pushed over the home and popped', (tester) async {
    final handle = tester.ensureSemantics();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Scaffold(
          appBar: AppBar(title: const Text('home')),
          body: ListView(
            children: [
              for (var i = 0; i < 20; i++)
                ListTile(title: Text('row $i'), onTap: () {}),
            ],
          ),
          bottomNavigationBar: const Row(
            children: [
              Expanded(child: TextField()),
              IconButton(
                tooltip: 'send',
                icon: Icon(Icons.send),
                onPressed: null,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    for (var round = 0; round < 3; round++) {
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('app')),
            body: const Center(child: Text('webview stand-in')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
    }
    expect(binding.sim.failures, isEmpty, reason: describe(binding.sim));
    handle.dispose();
  });

  testWidgets('framework bug: OverlayPortal child shown while its anchor is '
      'excluded from semantics for one frame', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = OverlayPortalController();
    final excluding = ValueNotifier<bool>(true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: excluding,
            builder: (context, value, _) => ExcludeSemantics(
              excluding: value,
              child: OverlayPortal(
                controller: controller,
                overlayChildBuilder: (context) => const Positioned(
                  left: 0,
                  bottom: 80,
                  child: SizedBox(width: 10, height: 10),
                ),
                child: const TextField(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    controller.show(); // overlay child appears while the anchor is hidden
    await tester.pump();
    excluding.value = false; // anchor appears one frame later
    await tester.pump();
    await tester.pump();
    expect(
      binding.sim.transitions,
      containsAllInOrder([
        matches(
          RegExp(r'^\d+ will not be in the tree and is not the new root$'),
        ),
        matches(RegExp(r'^Nodes left pending by the update: \d+$')),
      ]),
    );
    handle.dispose();
  });

  testWidgets('control: same portal shown after the anchor is in the tree', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final controller = OverlayPortalController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OverlayPortal(
            controller: controller,
            overlayChildBuilder: (context) => const Positioned(
              left: 0,
              bottom: 80,
              child: SizedBox(width: 10, height: 10),
            ),
            child: const TextField(),
          ),
        ),
      ),
    );
    await tester.pump();
    controller.show();
    await tester.pump();
    await tester.pump();
    expect(binding.sim.failures, isEmpty, reason: describe(binding.sim));
    handle.dispose();
  });
}
