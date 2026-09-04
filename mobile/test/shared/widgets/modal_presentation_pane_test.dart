import 'package:buzz/shared/layout/layout_mode.dart';
import 'package:buzz/shared/layout/pane_navigator.dart';
import 'package:buzz/shared/layout/pane_scope.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/widgets/modal_presentation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a sheet opened inside a pane presents on the root navigator '
      'and returns its result to the caller', (tester) async {
    final rootKey = GlobalKey<NavigatorState>();
    final depth = ValueNotifier<int>(0);
    late BuildContext paneContext;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootKey,
        theme: AppTheme.light(),
        home: PaneNavigator(
          kind: PaneKind.main,
          onClose: () {},
          depth: depth,
          child: Builder(
            builder: (context) {
              paneContext = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(depth.value, 1);

    final result = showBuzzModalBottomSheet<bool>(
      context: paneContext,
      builder: (sheetContext) => TextButton(
        key: const ValueKey('leave'),
        // Callers pop through the root navigator's context (see
        // channel_actions_sheet), which only closes the sheet when it lives
        // on the root navigator.
        onPressed: () => Navigator.of(
          Navigator.of(sheetContext, rootNavigator: true).context,
        ).pop(true),
        child: const Text('Leave'),
      ),
    );
    await tester.pumpAndSettle();

    expect(rootKey.currentState!.canPop(), isTrue);
    expect(depth.value, 1, reason: 'the pane navigator is untouched');

    await tester.tap(find.byKey(const ValueKey('leave')));
    await tester.pumpAndSettle();

    expect(await result, isTrue);
    expect(rootKey.currentState!.canPop(), isFalse);
  });

  testWidgets('outside a pane the sheet stays on the nearest navigator', (
    tester,
  ) async {
    final rootKey = GlobalKey<NavigatorState>();
    final nestedKey = GlobalKey<NavigatorState>();
    late BuildContext nestedContext;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootKey,
        theme: AppTheme.light(),
        home: Navigator(
          key: nestedKey,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) {
              nestedContext = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    showBuzzModalBottomSheet<void>(
      context: nestedContext,
      builder: (_) => const Text('Sheet'),
    );
    await tester.pumpAndSettle();

    expect(nestedKey.currentState!.canPop(), isTrue);
    expect(rootKey.currentState!.canPop(), isFalse);
  });

  testWidgets('the wide layout caps sheet width, intersecting explicit '
      'constraints', (tester) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext homeContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: LayoutModeScope(
          mode: LayoutMode.wide,
          child: Builder(
            builder: (context) {
              homeContext = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );

    showBuzzModalBottomSheet<void>(
      context: homeContext,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const SizedBox(
        key: ValueKey('sheet-body'),
        height: 200,
        width: double.infinity,
      ),
    );
    await tester.pumpAndSettle();

    final width = tester
        .getSize(find.byKey(const ValueKey('sheet-body')))
        .width;
    expect(width, lessThanOrEqualTo(kWideSheetMaxWidth));
    expect(width, greaterThan(kWideSheetMaxWidth - 40));
  });
}
