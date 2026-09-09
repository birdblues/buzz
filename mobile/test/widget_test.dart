import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:buzz/app.dart';
import 'package:buzz/shared/auth/auth.dart';
import 'package:buzz/shared/theme/theme_provider.dart';

void main() {
  testWidgets('App renders pairing page when unauthenticated', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(() => _FakeAuthNotifier()),
          savedPrefsProvider.overrideWithValue(prefs),
        ],
        child: const App(),
      ),
    );
    await tester.pump();
    expect(find.text('Welcome to Buzz'), findsOneWidget);
  });

  testWidgets(
    'App shows a retry screen, not pairing, when the sign-in cannot be read',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final auth = _FlakyAuthNotifier();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(() => auth),
            savedPrefsProvider.overrideWithValue(prefs),
          ],
          child: const App(),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The keychain said no — the user is not offered a fresh identity.
      expect(find.text('Welcome to Buzz'), findsNothing);
      expect(
        find.byKey(const ValueKey('startup-failure-retry')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Unexpected security result code'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('startup-failure-retry')));
      await tester.pump();
      await tester.pump();

      expect(auth.builds, greaterThanOrEqualTo(2));
      expect(find.text('Welcome to Buzz'), findsOneWidget);
    },
  );
}

/// Fails the first load the way flutter_secure_storage reports a keychain
/// error, then answers like an empty keychain.
class _FlakyAuthNotifier extends AuthNotifier {
  int builds = 0;

  @override
  Future<AuthState> build() async {
    builds += 1;
    if (builds == 1) {
      throw PlatformException(
        code: 'Unexpected security result code',
        message: 'Code: -34018, Message: A required entitlement is missing.',
        details: -34018,
      );
    }
    return const AuthState(status: AuthStatus.unauthenticated);
  }
}

class _FakeAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async {
    return const AuthState(status: AuthStatus.unauthenticated);
  }
}
