import 'package:buzz/features/channels/app_webview_page.dart';
import 'package:buzz/features/channels/message_content/app_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  group('decideAppNavigation', () {
    test('allows exactly the first main-frame load of the app document', () {
      expect(
        decideAppNavigation(
          request: const NavigationRequest(
            url: 'about:blank',
            isMainFrame: true,
          ),
          initialPending: true,
        ),
        NavigationDecision.navigate,
      );
      // The same request again (reload, window.open, a same-URL form post).
      expect(
        decideAppNavigation(
          request: const NavigationRequest(
            url: 'about:blank',
            isMainFrame: true,
          ),
          initialPending: false,
        ),
        NavigationDecision.prevent,
      );
      // A subframe pointing at the document URL.
      expect(
        decideAppNavigation(
          request: const NavigationRequest(
            url: 'about:blank',
            isMainFrame: false,
          ),
          initialPending: true,
        ),
        NavigationDecision.prevent,
      );
    });

    test('refuses every other navigation, even while the first is pending', () {
      for (final requested in [
        'https://example.com/?leak=1',
        'http://192.168.1.99:3001/app/$_sha.html',
        'http://192.168.1.99:3000/media/$_sha.html',
        'about:blank#frag',
        'about:srcdoc',
        'javascript:void(0)',
        'data:text/html,hi',
        'blob:null/abc',
        'file:///etc/passwd',
        '',
      ]) {
        expect(
          decideAppNavigation(
            request: NavigationRequest(url: requested, isMainFrame: true),
            initialPending: true,
          ),
          NavigationDecision.prevent,
          reason: requested,
        );
      }
    });
  });

  group('AppCard helpers', () {
    test('pickThemedPreview matches the theme and falls back', () {
      expect(
        pickThemedPreview(brightness: Brightness.light, light: 'l', dark: 'd'),
        'l',
      );
      expect(
        pickThemedPreview(brightness: Brightness.dark, light: 'l', dark: 'd'),
        'd',
      );
      expect(
        pickThemedPreview(brightness: Brightness.dark, light: 'l', dark: null),
        'l',
      );
      expect(
        pickThemedPreview(brightness: Brightness.light, light: null, dark: 'd'),
        'd',
      );
      expect(
        pickThemedPreview(
          brightness: Brightness.light,
          light: null,
          dark: null,
        ),
        isNull,
      );
    });

    test('formatAppFileSize', () {
      expect(formatAppFileSize(512), '512 B');
      expect(formatAppFileSize(20480), '20 KB');
      expect(formatAppFileSize(1536), '1.5 KB');
      expect(formatAppFileSize(8 * 1024 * 1024), '8.0 MB');
      expect(formatAppFileSize(-1), '');
    });
  });
}
