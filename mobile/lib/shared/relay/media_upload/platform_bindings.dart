part of '../media_upload.dart';

/// Whether saving media needs Android's pre-scoped-storage runtime permission.
Future<bool> requiresLegacyMediaStoragePermission() async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return false;
  }
  return await _mediaUploadPlatformChannel.invokeMethod<bool>(
        _requiresLegacyMediaStoragePermissionMethod,
      ) ??
      false;
}

final mediaUploadServiceProvider = Provider<MediaUploadService>((ref) {
  final config = ref.watch(relayConfigProvider);
  final picker = ImagePicker();
  final service = MediaUploadService(
    baseUrl: config.baseUrl,
    nsec: config.nsec,
    pickGalleryImage: () => picker.pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    ),
    // image_picker's camera source throws on macOS; the composer hides the
    // Camera entry there and the service treats a missing picker as "no
    // camera".
    pickCameraImage: hasCamera
        ? () => picker.pickImage(
            source: ImageSource.camera,
            requestFullMetadata: false,
          )
        : null,
    pickGalleryImages: () => picker.pickMultiImage(requestFullMetadata: false),
    pickGalleryVideo: () => picker.pickVideo(source: ImageSource.gallery),
    pickAttachmentFile: file_selector.openFile,
  );
  ref.onDispose(service.dispose);
  return service;
});
