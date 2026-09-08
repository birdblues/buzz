import CoreGraphics
import Foundation
import ImageIO

/// Re-encodes picked images for upload on macOS.
///
/// The relay refuses any image carrying EXIF, XMP, ICC, PNG text or a private
/// chunk (`crates/buzz-media/src/validation.rs`), so a picked file has to be
/// redrawn before it goes up. This does the redrawing only: it applies the
/// orientation, converts to sRGB, and hands back encoded bytes. Stripping what
/// the encoder itself writes — Apple's PNG output carries `eXIf`, `pHYs` and
/// `iDOT` — is Dart's job, in `image_container_scrub.dart`, so the container
/// rules live in one place instead of once per platform.
///
/// The iOS runner has a UIKit twin in `ios/Runner/MediaSanitizer.swift`.
enum MediaImageCodec {
  private static let pngIdentifier = "public.png" as CFString
  private static let jpegIdentifier = "public.jpeg" as CFString

  enum CodecError: Error {
    case decodeFailed
    case encodeFailed
  }

  /// Redraws `data` and returns it as PNG, or as JPEG when asked for one.
  ///
  /// WebP comes back as PNG, matching iOS. The Dart side reads the type back
  /// off the returned bytes, so the container is free to change here.
  static func encodeForUpload(_ data: Data, mimeType: String) throws -> Data {
    switch mimeType {
    case "image/jpeg":
      return try encodeJpeg(data)
    case "image/png", "image/webp":
      return try encodePng(data)
    default:
      throw CodecError.encodeFailed
    }
  }

  /// Redraws `data` as PNG, whatever it arrived as.
  ///
  /// The clipboard path uses this: macOS often holds a copied picture only as
  /// TIFF, which the upload path has no name for, and declaring it something
  /// it is not fails in the scrubber instead.
  static func encodePng(_ data: Data) throws -> Data {
    let image = try decodeOriented(data)
    return try encode(image, as: pngIdentifier, quality: nil)
  }

  /// Redraws `data` as JPEG. This is the HEIC path, and anything else the
  /// Dart side could not identify.
  static func encodeJpeg(_ data: Data) throws -> Data {
    let image = try decodeOriented(data, opaque: true)
    return try encode(image, as: jpegIdentifier, quality: 1.0)
  }

  /// Decodes the primary frame at full size with its EXIF orientation applied,
  /// then redraws it in sRGB.
  ///
  /// The orientation has to be baked into the pixels here, because the tag
  /// recording it is metadata the relay rejects: dropping the tag without
  /// redrawing would lay every portrait photo on its side.
  ///
  /// `kCGImageSourceCreateThumbnailFromImageAlways` is what makes this the
  /// full image rather than whatever small preview the file happens to embed,
  /// and `WithTransform` is what applies the orientation. Both are required;
  /// with only the latter, ImageIO returns the embedded thumbnail or nothing
  /// at all. `NativeEmojiPickerView.swift` in the iOS runner uses the same
  /// quartet of options.
  private static func decodeOriented(_ data: Data, opaque: Bool = false) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw CodecError.decodeFailed
    }
    // A HEIC file can hold thumbnails and depth maps beside the photo.
    let index = CGImageSourceGetPrimaryImageIndex(source)
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
        as? [CFString: Any],
      let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
      let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
      pixelWidth > 0, pixelHeight > 0
    else {
      throw CodecError.decodeFailed
    }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let oriented = CGImageSourceCreateThumbnailAtIndex(
        source,
        index,
        options as CFDictionary
      )
    else {
      throw CodecError.decodeFailed
    }
    return try redrawInSRGB(oriented, opaque: opaque)
  }

  /// Draws `image` into a fresh sRGB bitmap.
  ///
  /// Drawing is what converts the colour. `CGImageCreateCopyWithColorSpace`
  /// would relabel the pixels instead, so a Display-P3 photo would shift once
  /// its profile was stripped.
  private static func redrawInSRGB(_ image: CGImage, opaque: Bool) throws -> CGImage {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { throw CodecError.decodeFailed }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw CodecError.encodeFailed
    }

    // JPEG has no alpha channel, so a transparent source is composited on
    // white rather than coming out black.
    let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: alphaInfo.rawValue
      )
    else {
      throw CodecError.encodeFailed
    }

    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    if opaque {
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(bounds)
    }
    context.interpolationQuality = .high
    context.draw(image, in: bounds)

    guard let redrawn = context.makeImage() else { throw CodecError.encodeFailed }
    return redrawn
  }

  private static func encode(
    _ image: CGImage,
    as identifier: CFString,
    quality: CGFloat?
  ) throws -> Data {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output as CFMutableData,
        identifier,
        1,
        nil
      )
    else {
      throw CodecError.encodeFailed
    }

    var options: [CFString: Any] = [:]
    if let quality {
      options[kCGImageDestinationLossyCompressionQuality] = quality
    }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CodecError.encodeFailed }
    return output as Data
  }
}
