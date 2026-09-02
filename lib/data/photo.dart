/// Preparing a bottle photograph for the model.
///
/// =============================================================================
/// WHY RESIZE AT ALL
/// =============================================================================
/// Claude downscales any image whose longest edge exceeds 1568px before it looks
/// at it. Sending a 12-megapixel phone photo therefore uploads about twenty
/// times more data than the model will ever see — paying, in the user's mobile
/// data and in the seconds they stand waiting, for pixels that are discarded on
/// arrival.
///
/// Image tokens scale with area (roughly `w * h / 750`), so the resize is also
/// most of the cost control on the identify path.
///
/// =============================================================================
/// WHY NOT flutter_image_compress
/// =============================================================================
/// It has no Windows implementation, and Windows is this project's development
/// harness: an emulator's camera renders a synthetic scene, so bottle
/// identification cannot be developed against it. The decode below uses
/// `dart:ui`, which is native and fast on every platform, and only the small
/// resized result is handed to the pure-Dart JPEG encoder — so the expensive
/// half stays native and the portable half stays cheap.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

// The bounds live in photo_limits.dart, which has no Flutter dependency, so the
// eval harness can resize to exactly the same numbers without dart:ui.
export 'photo_limits.dart' show jpegQuality, maxImageEdge;

import 'photo_limits.dart';

/// A photo, resized and re-encoded ready to send.
class PreparedPhoto {
  const PreparedPhoto({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  /// Roughly what this image will cost in input tokens — `w * h / 750`.
  ///
  /// Surfaced so the cost of the resize decision is inspectable rather than
  /// asserted, and so the eval harness can report tokens alongside accuracy.
  int get approximateTokens => (width * height / 750).round();
}

/// Decodes, downscales to fit [maxImageEdge], and re-encodes as JPEG.
///
/// An image already within the bound is still re-encoded: a 4MB PNG of a small
/// bottle is common from a screenshot and costs the same upload time as a large
/// photograph.
Future<PreparedPhoto> preparePhoto(Uint8List input) async {
  // ---------------------------------------------------------------------------
  // WHY THIS PROBES FIRST INSTEAD OF ASKING FOR THE SIZE
  //
  // The obvious version reads the dimensions from `ui.ImageDescriptor.encoded`
  // and instantiates the codec straight at the target size — one decode, no
  // full-resolution bitmap. That is what this function used to do, and it
  // throws on Flutter web:
  //
  //   Unsupported operation: ImageDescriptor.width is not supported on web.
  //
  // Which meant every scan on the web build — the build the app is actually
  // deployed as, and the only one an iPhone can run — failed at the first step.
  // It was never caught because the eval harness resizes with `package:image`
  // instead, and no test could see it: `flutter test` runs on the VM, where
  // ImageDescriptor works fine.
  //
  // `instantiateImageCodec` IS supported everywhere, so the image is decoded
  // once at native size purely to learn its dimensions, then decoded again at
  // the target size when it is too big. The second decode is the cost of
  // portability; an image already within the bound pays nothing extra.
  // ---------------------------------------------------------------------------
  var codec = await ui.instantiateImageCodec(input);
  var image = (await codec.getNextFrame()).image;

  final (targetWidth, targetHeight) =
      _fit(image.width, image.height, maxImageEdge);

  if (targetWidth != image.width || targetHeight != image.height) {
    image.dispose();
    codec.dispose();
    codec = await ui.instantiateImageCodec(
      input,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    image = (await codec.getNextFrame()).image;
  }

  try {
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) {
      throw StateError('could not read pixels from the decoded image');
    }

    // The result is at most 1568px on its longest edge, so the pure-Dart
    // encode below is operating on a small buffer and stays fast.
    final encoded = img.encodeJpg(
      img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: rgba.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      ),
      quality: jpegQuality,
    );

    return PreparedPhoto(
      bytes: Uint8List.fromList(encoded),
      width: image.width,
      height: image.height,
    );
  } finally {
    image.dispose();
    codec.dispose();
  }
}

/// Scales `(width, height)` down to fit within `limit` on the longest edge,
/// preserving aspect ratio. An image already inside the bound is unchanged.
///
/// Rounds to at least 1px on both axes: a very wide, very short panorama scaled
/// naively rounds its short edge to zero, and a zero-height codec target throws
/// rather than producing a picture.
(int, int) _fit(int width, int height, int limit) {
  if (width <= 0 || height <= 0) return (1, 1);
  final longest = width > height ? width : height;
  if (longest <= limit) return (width, height);
  final scale = limit / longest;
  return (
    (width * scale).round().clamp(1, limit),
    (height * scale).round().clamp(1, limit),
  );
}

/// Exposed for tests — the geometry is the part worth pinning, and it needs no
/// decoder to check.
(int, int) fitWithinForTest(int width, int height, int limit) =>
    _fit(width, height, limit);
