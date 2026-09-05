import 'link_preview_metadata.dart';

/// YouTube watch pages serve a consent wall to anonymous fetchers, so they
/// preview through the public oEmbed endpoint instead, as desktop does
/// (`link_preview_youtube.rs`).
const youTubeOEmbedEndpoint = 'https://www.youtube.com/oembed';

const _shortHosts = {'youtu.be', 'www.youtu.be'};
const _watchHosts = {
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
};
const _pathVideoPrefixes = {'shorts', 'live', 'embed'};
final _videoId = RegExp(r'^[A-Za-z0-9_-]+$');

/// Whether [url] names one video: `youtu.be/<id>`, `/watch?v=<id>`, or
/// `/shorts|live|embed/<id>`.
bool isYouTubeVideoUrl(Uri url) {
  final host = url.host.toLowerCase();
  final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
  if (_shortHosts.contains(host)) return segments.isNotEmpty;
  if (!_watchHosts.contains(host)) return false;
  if (url.path == '/watch') {
    final id = url.queryParameters['v'];
    return id != null && id.isNotEmpty;
  }
  return segments.length >= 2 && _pathVideoPrefixes.contains(segments[0]);
}

/// The oEmbed request for [video]. An `/embed/<id>` URL is rewritten to the
/// canonical `/watch?v=<id>` form the endpoint understands; null when the
/// embed id is malformed.
Uri? youTubeOEmbedUri(Uri video) {
  var canonical = video;
  final segments = video.pathSegments.where((s) => s.isNotEmpty).toList();
  if (_watchHosts.contains(video.host.toLowerCase()) &&
      segments.isNotEmpty &&
      segments[0] == 'embed') {
    if (segments.length < 2 || !_videoId.hasMatch(segments[1])) return null;
    canonical = Uri.https(video.host, '/watch', {'v': segments[1]});
  }
  return Uri.parse(
    youTubeOEmbedEndpoint,
  ).replace(queryParameters: {'format': 'json', 'url': canonical.toString()});
}

/// The preview an oEmbed document yields: its title, the provider (falling
/// back to "YouTube"), the channel name as the description, and the
/// thumbnail to fetch. Null without a usable title.
({LinkPreviewMetadata metadata, Uri? thumbnailUrl})? metadataFromYouTubeOEmbed(
  Map<String, Object?> json,
) {
  final rawTitle = json['title'];
  if (rawTitle is! String) return null;
  final title = normalizeMetadataText(rawTitle);
  if (title == null) return null;
  final provider = json['provider_name'];
  final author = json['author_name'];
  final thumbnail = json['thumbnail_url'];
  return (
    metadata: LinkPreviewMetadata(
      title: title,
      siteName:
          (provider is String ? normalizeMetadataText(provider) : null) ??
          'YouTube',
      description: author is String
          ? normalizeMetadataDescription(author)
          : null,
    ),
    thumbnailUrl: thumbnail is String ? Uri.tryParse(thumbnail) : null,
  );
}
