import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../shared/link_preview/link_preview_fetcher.dart';
import '../../shared/link_preview/link_preview_image.dart';
import '../../shared/link_preview/link_preview_metadata.dart';
import 'message_content/link_preview_candidates.dart';
import 'message_content/link_preview_snapshot.dart';

/// Idle time after the last keystroke before a draft's links are previewed,
/// so typing a URL does not start a fetch per character.
const composerLinkPreviewDebounce = Duration(milliseconds: 350);

/// How long a send waits for previews still in flight before going out
/// without them. Sends never fail because a preview did.
const composerLinkPreviewSendBudget = Duration(seconds: 6);

/// How long a captured snapshot is reused when the same URL re-enters a
/// draft, so retyping a link is instant and hits the site only once.
const composerLinkPreviewCacheTtl = Duration(minutes: 5);

/// Uploads sanitized preview media to the relay: returns the blob's URL and
/// sha256, or throws.
typedef UploadLinkPreviewMedia =
    Future<({String url, String sha256})> Function(
      Uint8List bytes,
      String mimeType,
    );

enum ComposerLinkPreviewStatus { loading, ready, failed }

/// One link of the draft and where its preview stands.
@immutable
class ComposerLinkPreview {
  final String url;
  final ComposerLinkPreviewStatus status;
  final LinkPreviewMetadata? metadata;

  /// The sanitized page image, for the composer card; null before the
  /// capture lands or when the page has none.
  final Uint8List? imageBytes;

  /// The snapshot tag to send, present once the capture and any uploads
  /// settled (uploads that failed leave a media-less tag).
  final List<String>? tag;

  const ComposerLinkPreview({
    required this.url,
    required this.status,
    this.metadata,
    this.imageBytes,
    this.tag,
  });

  String get hostname {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }
}

class _Snapshot {
  final LinkPreviewMetadata metadata;
  final Uint8List? imageBytes;
  final List<String> tag;
  final DateTime capturedAt;

  const _Snapshot({
    required this.metadata,
    required this.imageBytes,
    required this.tag,
    required this.capturedAt,
  });
}

final Map<String, _Snapshot> _snapshotCache = {};

/// Drops every cached snapshot (community switch: blob URLs belong to the
/// old relay).
void clearComposerLinkPreviewCache() => _snapshotCache.clear();

/// The link previews of one composer draft, authored the way desktop's
/// `useComposerLinkPreviews` does it (`docs/link-previews.md`): every https
/// link in the visible body is fetched once, its image and favicon are
/// re-hosted on the relay, and the result becomes a signed snapshot tag on
/// the outgoing event. The sender can hide all previews for the message,
/// which sends `["link-preview","none"]` instead.
class ComposerLinkPreviewsController extends ChangeNotifier {
  final LinkPreviewFetcher _fetcher;
  final UploadLinkPreviewMedia _upload;
  final Duration _debounce;
  final DateTime Function() _now;

  final Map<String, ComposerLinkPreview> _previews = {};
  final Map<String, int> _generations = {};
  final Map<String, Future<void>> _jobs = {};
  List<String> _order = const [];
  bool _suppressed = false;
  bool _disposed = false;
  Timer? _debounceTimer;
  String _content = '';

  ComposerLinkPreviewsController({
    required LinkPreviewFetcher fetcher,
    required UploadLinkPreviewMedia upload,
    Duration debounce = composerLinkPreviewDebounce,
    DateTime Function()? now,
  }) : _fetcher = fetcher,
       _upload = upload,
       _debounce = debounce,
       _now = now ?? DateTime.now;

  /// Previews in the order their links appear in the draft.
  List<ComposerLinkPreview> get previews => [
    for (final url in _order) ?_previews[url],
  ];

  /// Whether the sender chose to send this message without previews.
  bool get suppressed => _suppressed;

  bool get hasPending => _previews.values.any(
    (preview) => preview.status == ComposerLinkPreviewStatus.loading,
  );

  /// The draft changed. Links are re-extracted after [composerLinkPreviewDebounce];
  /// links that left the draft drop at once so a stale card never lingers.
  void updateContent(String content) {
    if (_disposed) return;
    _content = content;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => _apply(_content));
  }

  /// Send this message without previews.
  void suppress() {
    if (_disposed || _suppressed) return;
    _suppressed = true;
    notifyListeners();
  }

  /// Forget everything: the message was sent or the draft discarded.
  void clear() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _content = '';
    _suppressed = false;
    for (final url in _previews.keys.toList()) {
      _retire(url);
    }
    _order = const [];
    if (!_disposed) notifyListeners();
  }

  /// The tags for a send of [content] right now: the suppression marker, or
  /// the ready snapshot for each link still in the body, waiting at most
  /// [budget] for ones in flight. Links whose preview never settled send as
  /// bare links.
  Future<List<List<String>>> tagsForSend(
    String content, {
    Duration budget = composerLinkPreviewSendBudget,
  }) async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final live = extractLinkPreviewCandidates(content);
    if (live.isEmpty) return const [];
    if (_suppressed) return [List.of(linkPreviewSuppressionTag)];
    _apply(content);
    final pending = [for (final url in live) ?_jobs[url]];
    if (pending.isNotEmpty) {
      try {
        await Future.wait(pending).timeout(budget);
      } on TimeoutException {
        // Send without the stragglers; a later retry of the same link will
        // find the cache warm.
      }
    }
    return [
      for (final url in live)
        if (_previews[url]?.tag case final tag?) List.of(tag),
    ];
  }

  void _apply(String content) {
    if (_disposed) return;
    final candidates = extractLinkPreviewCandidates(content);
    final active = candidates.toSet();
    for (final url in _previews.keys.toList()) {
      if (!active.contains(url)) _retire(url);
    }
    for (final url in candidates) {
      if (!_previews.containsKey(url)) _start(url);
    }
    _order = candidates;
    if (candidates.isEmpty) _suppressed = false;
    notifyListeners();
  }

  void _retire(String url) {
    _generations[url] = (_generations[url] ?? 0) + 1;
    _previews.remove(url);
    _jobs.remove(url);
  }

  void _start(String url) {
    final generation = (_generations[url] ?? 0) + 1;
    _generations[url] = generation;
    final cached = _snapshotCache[url];
    if (cached != null &&
        _now().difference(cached.capturedAt) < composerLinkPreviewCacheTtl) {
      _previews[url] = ComposerLinkPreview(
        url: url,
        status: ComposerLinkPreviewStatus.ready,
        metadata: cached.metadata,
        imageBytes: cached.imageBytes,
        tag: cached.tag,
      );
      return;
    }
    _previews[url] = ComposerLinkPreview(
      url: url,
      status: ComposerLinkPreviewStatus.loading,
    );
    final job = _run(url, generation);
    _jobs[url] = job;
    unawaited(
      job.whenComplete(() {
        if (_jobs[url] == job) _jobs.remove(url);
      }),
    );
  }

  bool _isCurrent(String url, int generation) =>
      !_disposed && _generations[url] == generation;

  Future<void> _run(String url, int generation) async {
    final capture = await _fetcher.fetch(Uri.parse(url));
    if (!_isCurrent(url, generation)) return;
    if (capture == null) {
      _previews[url] = ComposerLinkPreview(
        url: url,
        status: ComposerLinkPreviewStatus.failed,
      );
      notifyListeners();
      return;
    }
    final metadata = capture.metadata;
    final hostname = _previews[url]?.hostname ?? '';
    final siteName = metadata.siteName ?? hostname;
    final description = metadata.description ?? '';
    // Show the card as soon as the page is read; uploads follow.
    _previews[url] = ComposerLinkPreview(
      url: url,
      status: ComposerLinkPreviewStatus.loading,
      metadata: metadata,
      imageBytes: capture.image?.bytes,
    );
    notifyListeners();

    var imageUrl = '';
    var imageSha = '';
    var faviconUrl = '';
    var faviconSha = '';
    try {
      final (image, favicon) = await (
        _uploadOrNull(capture.image),
        _uploadOrNull(capture.favicon),
      ).wait;
      if (image != null) (imageUrl, imageSha) = (image.url, image.sha256);
      if (favicon != null) {
        (faviconUrl, faviconSha) = (favicon.url, favicon.sha256);
      }
    } catch (_) {
      // Media is optional; the text-only snapshot still previews.
    }
    if (!_isCurrent(url, generation)) return;
    final tag = buildLinkPreviewSnapshotTag(
      canonicalUrl: url,
      title: metadata.title,
      siteName: siteName,
      description: description,
      imageUrl: imageUrl,
      imageSha256: imageSha,
      faviconUrl: faviconUrl,
      faviconSha256: faviconSha,
    );
    if (tag == null) {
      _previews[url] = ComposerLinkPreview(
        url: url,
        status: ComposerLinkPreviewStatus.failed,
      );
      notifyListeners();
      return;
    }
    _snapshotCache[url] = _Snapshot(
      metadata: metadata,
      imageBytes: capture.image?.bytes,
      tag: tag,
      capturedAt: _now(),
    );
    _previews[url] = ComposerLinkPreview(
      url: url,
      status: ComposerLinkPreviewStatus.ready,
      metadata: metadata,
      imageBytes: capture.image?.bytes,
      tag: tag,
    );
    notifyListeners();
  }

  Future<({String url, String sha256})?> _uploadOrNull(
    SanitizedLinkPreviewImage? image,
  ) async {
    if (image == null) return null;
    return _upload(image.bytes, image.mimeType);
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
