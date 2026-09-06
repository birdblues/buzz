import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  NostrEvent profile(int index) => NostrEvent(
    id: 'profile-$index',
    pubkey: 'pubkey-$index',
    createdAt: 1700000000 - index,
    kind: 0,
    tags: const [],
    content: '{}',
    sig: 'sig',
  );

  group('queryRelayPages', () {
    test('walks pages until one comes back short', () async {
      final session = _PagedRelaySession(
        List.generate(120, profile),
        pageSize: 50,
      );

      final events = await queryRelayPages(
        session,
        const NostrFilter(kinds: [0], limit: 50),
      );

      expect(
        events.map((event) => event.id),
        List.generate(120, (i) => 'profile-$i'),
      );
      expect(session.requestedPages, [1, 2, 3]);
    });

    test('stops after an exact multiple of the page size', () async {
      final session = _PagedRelaySession(
        List.generate(100, profile),
        pageSize: 50,
      );

      final events = await queryRelayPages(
        session,
        const NostrFilter(kinds: [0], limit: 50),
      );

      expect(events, hasLength(100));
      // Page 3 is empty and ends the walk; nothing is fetched beyond it.
      expect(session.requestedPages, [1, 2, 3]);
    });

    test('keeps the caller\'s filter and adds only the page', () async {
      final session = _PagedRelaySession(
        List.generate(3, profile),
        pageSize: 50,
      );

      await queryRelayPages(
        session,
        const NostrFilter(
          kinds: [0],
          limit: 50,
          search: 'ali',
          extensions: {'search_mode': 'prefix'},
        ),
      );

      final sent = session.filters.single.single;
      expect(sent.kinds, [0]);
      expect(sent.limit, 50);
      expect(sent.search, 'ali');
      expect(sent.extensions, {'search_mode': 'prefix', 'page': 1});
    });

    test('stops when a relay ignores the page and repeats itself', () async {
      final session = _PagedRelaySession(
        List.generate(50, profile),
        pageSize: 50,
        ignoresPage: true,
      );

      final events = await queryRelayPages(
        session,
        const NostrFilter(kinds: [0], limit: 50),
      );

      expect(events, hasLength(50));
      expect(session.requestedPages, [1, 2]);
    });

    test('stops at the page ceiling', () async {
      final session = _PagedRelaySession(
        List.generate(500, profile),
        pageSize: 50,
      );

      final events = await queryRelayPages(
        session,
        const NostrFilter(kinds: [0], limit: 50),
        maxPages: 3,
      );

      expect(events, hasLength(150));
      expect(session.requestedPages, [1, 2, 3]);
    });

    test('a failed page fails the whole listing', () async {
      final session = _PagedRelaySession(
        List.generate(120, profile),
        pageSize: 50,
        failOnPage: 2,
      );

      await expectLater(
        queryRelayPages(session, const NostrFilter(kinds: [0], limit: 50)),
        throwsA(isA<StateError>()),
      );
      expect(session.requestedPages, [1, 2]);
    });
  });
}

class _PagedRelaySession extends RelaySessionNotifier {
  _PagedRelaySession(
    this.events, {
    required this.pageSize,
    this.ignoresPage = false,
    this.failOnPage,
  });

  final List<NostrEvent> events;
  final int pageSize;
  final bool ignoresPage;
  final int? failOnPage;
  final requestedPages = <int>[];
  final filters = <List<NostrFilter>>[];

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    this.filters.add(filters);
    final page = filters.single.extensions['page'] as int;
    requestedPages.add(page);
    if (page == failOnPage) {
      throw StateError('relay unavailable');
    }
    final effectivePage = ignoresPage ? 1 : page;
    final start = (effectivePage - 1) * pageSize;
    if (start >= events.length) return const [];
    return events.sublist(start, (start + pageSize).clamp(0, events.length));
  }
}
