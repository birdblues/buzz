import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
    'App shows a retry screen, not pairing, when the sign-in cannot be read, '
    'and Try again recovers the community list too',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      // Every read during the launch window fails the way the macOS keychain
      // does right after a relaunch; the window closes before Try again.
      final keychain = _FlakySecureStorage(
        failures: CommunityStorage.readAttempts * 2,
      );
      late ProviderContainer container;

      await tester.pumpWidget(
        ProviderScope(
          // The app's own retry, not Riverpod's, is under test.
          retry: (_, _) => null,
          overrides: [
            communityStorageProvider.overrideWithValue(
              CommunityStorage(secure: keychain),
            ),
            savedPrefsProvider.overrideWithValue(prefs),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const App();
            },
          ),
        ),
      );
      // The home reads the community list during the same window.
      unawaited(
        container
            .read(communityListProvider.future)
            .catchError((_) => <Community>[]),
      );
      // Let the storage retries run out.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      // The keychain said no — the user is not offered a fresh identity.
      expect(find.text('Welcome to Buzz'), findsNothing);
      expect(
        find.byKey(const ValueKey('startup-failure-retry')),
        findsOneWidget,
      );
      expect(find.textContaining('-25308'), findsOneWidget);
      expect(keychain.failures, 0, reason: 'both loads exhausted the window');
      expect(container.read(communityListProvider).hasError, isTrue);

      await tester.tap(find.byKey(const ValueKey('startup-failure-retry')));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(find.text('Welcome to Buzz'), findsOneWidget);
      expect(container.read(authProvider).hasValue, isTrue);
      expect(
        container.read(communityListProvider).hasValue,
        isTrue,
        reason: 'the list must recover with the sign-in, not stay in error',
      );
    },
  );
}

/// Fails the first [failures] reads the way flutter_secure_storage reports
/// `errSecInteractionNotAllowed`, then behaves like an empty keychain.
class _FlakySecureStorage extends Fake implements FlutterSecureStorage {
  _FlakySecureStorage({required this.failures});

  int failures;
  final Map<String, String> _data = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failures > 0) {
      failures -= 1;
      throw PlatformException(
        code: 'Unexpected security result code',
        message: 'Code: -25308, Message: User interaction is not allowed.',
        details: -25308,
      );
    }
    return _data[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _data.remove(key);
  }
}

class _FakeAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async {
    return const AuthState(status: AuthStatus.unauthenticated);
  }
}
