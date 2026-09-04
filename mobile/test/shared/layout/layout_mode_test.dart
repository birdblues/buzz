import 'package:buzz/shared/layout/layout_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('layoutModeForSize', () {
    test('is compact below the minimum width', () {
      expect(
        layoutModeForSize(const Size(kWideLayoutMinWidth - 1, 800)),
        LayoutMode.compact,
      );
      expect(
        layoutModeForSize(const Size(kWideLayoutMinWidth, 800)),
        LayoutMode.wide,
      );
    });

    test('keeps landscape phones compact via the shortest side', () {
      // iPhone Pro Max landscape.
      expect(layoutModeForSize(const Size(956, 440)), LayoutMode.compact);
    });

    test('is wide for iPad landscape sizes', () {
      expect(layoutModeForSize(const Size(1194, 834)), LayoutMode.wide);
      expect(layoutModeForSize(const Size(1024, 768)), LayoutMode.wide);
    });

    test('every iPad fits three columns', () {
      expect(
        kWideSidebarWidth + kWideMainPaneMinWidth + kWideAuxPaneWidth,
        lessThanOrEqualTo(1024),
      );
      expect(
        kWideSidebarWidth + kWideMainPaneMinWidth + kWideAuxPaneWidth,
        lessThanOrEqualTo(kWideLayoutMinWidth + 24),
      );
    });
  });

  group('LayoutModeScope', () {
    testWidgets('falls back to the window size without a scope', (
      tester,
    ) async {
      late LayoutMode mode;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(1194, 834)),
          child: Builder(
            builder: (context) {
              mode = LayoutModeScope.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(mode, LayoutMode.wide);
    });

    testWidgets('wins over a narrower MediaQuery inside a pane', (
      tester,
    ) async {
      late LayoutMode mode;
      await tester.pumpWidget(
        LayoutModeScope(
          mode: LayoutMode.wide,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(340, 834)),
            child: Builder(
              builder: (context) {
                mode = LayoutModeScope.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(mode, LayoutMode.wide);
    });
  });
}
