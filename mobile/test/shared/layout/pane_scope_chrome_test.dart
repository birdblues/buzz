import 'package:buzz/shared/layout/pane_navigator.dart';
import 'package:buzz/shared/layout/pane_scope.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/widgets/frosted_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _page({required String title, List<Widget> actions = const []}) =>
    Scaffold(
      body: Stack(
        children: [
          FrostedAppBar(
            automaticallyImplyLeading: false,
            title: Text(title),
            actions: actions,
          ),
        ],
      ),
    );

void main() {
  testWidgets('outside a pane the app bar is unchanged', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _page(
          title: 'Activity',
          actions: const [Icon(Icons.filter_list, key: ValueKey('filter'))],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('filter')), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('a pane injects its chrome at the root and keeps the trailing '
      'control on pushed routes', (tester) async {
    late BuildContext rootContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: PaneNavigator(
          kind: PaneKind.aux,
          onClose: () {},
          headerLeading: const Icon(Icons.menu, key: ValueKey('pane-leading')),
          headerTrailing: const Icon(Icons.close, key: ValueKey('pane-close')),
          child: Builder(
            builder: (context) {
              rootContext = context;
              return _page(
                title: 'Thread',
                actions: const [Icon(Icons.more_horiz, key: ValueKey('more'))],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pane-leading')), findsOneWidget);
    expect(find.byKey(const ValueKey('pane-close')), findsOneWidget);
    // Existing actions come first; the pane control is appended.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('more'))).dx,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('pane-close'))).dx),
    );

    Navigator.of(
      rootContext,
    ).push(MaterialPageRoute<void>(builder: (_) => _page(title: 'Nested')));
    await tester.pumpAndSettle();

    expect(find.text('Nested'), findsOneWidget);
    expect(find.byKey(const ValueKey('pane-leading')), findsNothing);
    expect(find.byKey(const ValueKey('pane-close')), findsOneWidget);
  });
}
