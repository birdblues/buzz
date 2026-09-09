import 'dart:convert';

import 'package:buzz/features/channels/sandbox_app_state.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _state({
  Object? view = 'compressed',
  Object? t = 3,
  Object? collapsed = const ['g_a'],
  Object? sel = const ['n1', 'e2'],
  Object? zoom = 1.5,
  Object? panX = 10,
  Object? panY = -20,
  Object? moved = const {
    'n1': {'x': 120, 'y': 40},
  },
}) => {
  'v': 1,
  'view': view,
  't': t,
  'collapsed': collapsed,
  'sel': sel,
  'includeFeedback': true,
  'cam': {
    'zoom': zoom,
    'pan': {'x': panX, 'y': panY},
  },
  'moved': moved,
};

void main() {
  group('canonicalSandboxAppState', () {
    test('keeps a valid state, in canonical field order', () {
      final canonical = canonicalSandboxAppState(_state());
      expect(canonical, isNotNull);
      final decoded = jsonDecode(canonical!) as Map<String, dynamic>;
      expect(decoded['v'], 1);
      expect(decoded['view'], 'compressed');
      expect(decoded['t'], 3);
      expect(decoded['collapsed'], ['g_a']);
      expect(decoded['sel'], ['n1', 'e2']);
      expect(decoded['includeFeedback'], isTrue);
      expect(decoded['cam'], {
        'zoom': 1.5,
        'pan': {'x': 10, 'y': -20},
      });
      expect(decoded['moved'], {
        'n1': {'x': 120, 'y': 40},
      });
    });

    test('drops extra fields and defaults missing lists', () {
      final raw = _state()
        ..remove('collapsed')
        ..remove('moved')
        ..['extra'] = 'x';
      final decoded =
          jsonDecode(canonicalSandboxAppState(raw)!) as Map<String, dynamic>;
      expect(decoded.containsKey('extra'), isFalse);
      expect(decoded['collapsed'], isEmpty);
      expect(decoded['moved'], isEmpty);
    });

    test('refuses anything off the schema, whole', () {
      final rejected = <String, Object?>{
        'not a map': 'x',
        'wrong version': _state()..['v'] = 2,
        'unknown view': _state(view: 'orbit'),
        'fractional t': _state(t: 1.5),
        'negative t': _state(t: -1),
        'zoom too small': _state(zoom: 0.001),
        'zoom not a number': _state(zoom: 'big'),
        'pan out of range': _state(panX: 1e7),
        'sel not strings': _state(sel: [1, 2]),
        'empty id in sel': _state(sel: ['']),
        'too many sel': _state(sel: List.filled(501, 'n')),
        'moved as a list': _state(moved: ['n1']),
        'moved point off': _state(
          moved: {
            'n1': {'x': 'far', 'y': 0},
          },
        ),
        'moved out of range': _state(
          moved: {
            'n1': {'x': 1e6, 'y': 0},
          },
        ),
        'too many moved': _state(
          moved: {
            for (var i = 0; i < 501; i++) 'n$i': {'x': 0, 'y': 0},
          },
        ),
      };
      rejected.forEach((label, raw) {
        expect(canonicalSandboxAppState(raw), isNull, reason: label);
      });
    });
  });

  group('sandboxAppStateToBase64', () {
    test('takes only a JSON string and returns base64 of canonical JSON', () {
      final b64 = sandboxAppStateToBase64(jsonEncode(_state()));
      expect(b64, isNotNull);
      final back = utf8.decode(base64Decode(b64!));
      expect(back, canonicalSandboxAppState(_state()));
      expect(sandboxAppStateToBase64(_state()), isNull, reason: 'a map');
      expect(sandboxAppStateToBase64(42), isNull);
      expect(sandboxAppStateToBase64('null'), isNull);
      expect(sandboxAppStateToBase64('{not json'), isNull);
    });

    test('carries ids that would break a JS string literal', () {
      // U+2028 / U+2029 are line terminators inside a JS literal and
      // jsonEncode leaves them raw; base64 makes the transport indifferent.
      const hostile = 'a\u2028b\u2029c"\'\\</script>😀';
      final b64 = sandboxAppStateToBase64(jsonEncode(_state(sel: [hostile])));
      expect(b64, matches(RegExp(r'^[A-Za-z0-9+/=]+$')));
      final decoded =
          jsonDecode(utf8.decode(base64Decode(b64!))) as Map<String, dynamic>;
      expect(decoded['sel'], [hostile]);
    });

    test('refuses an oversized export', () {
      final big = jsonEncode(_state(sel: List.filled(400, 'x' * 200)));
      expect(utf8.encode(big).length, greaterThan(sandboxAppStateMaxBytes));
      expect(sandboxAppStateToBase64(big), isNull);
    });
  });
}
