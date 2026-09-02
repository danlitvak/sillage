/// Image preparation, tested on the VM **and in a real browser**.
///
/// =============================================================================
/// RUN THIS ON CHROME OR IT PROVES NOTHING
/// =============================================================================
///     flutter test test/photo_test.dart                     (VM)
///     flutter test --platform chrome test/photo_test.dart   (the one that matters)
///
/// `preparePhoto` used to decode through `ui.ImageDescriptor.encoded`. That
/// works on every native target and throws on web:
///
///     Unsupported operation: ImageDescriptor.width is not supported on web.
///
/// So every scan on the deployed build — the web build, the only one an iPhone
/// can run — died at the first step, while `flutter test` stayed green because
/// the VM supports the API just fine. The whole suite passed and the app was
/// broken for every real user.
///
/// A test is only evidence on the platform it runs on. These cases exist to be
/// run under `--platform chrome`, where they would have caught it immediately.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sillage/data/photo.dart';

/// Every call to `preparePhoto` runs inside `tester.runAsync`.
///
/// `testWidgets` installs a FakeAsync zone, and image decoding is REAL async
/// work handed to the engine — inside that zone the future never completes and
/// the test hangs forever rather than failing. `runAsync` steps outside it.
///
/// A real encoded JPEG of the requested size, built in pure Dart so this needs
/// no asset and no file system — which is what lets it run in a browser.
Uint8List syntheticJpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  // Not a flat fill: a flat image compresses to almost nothing and would hide
  // any problem that depends on real pixel data being present.
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 7) % 256, (y * 11) % 256, ((x + y) * 3) % 256);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('preparePhoto works on this platform', () {
    testWidgets('a large photo is decoded and downscaled', (tester) async {
      // 2400x1800 stands in for a phone photo: over the bound on both axes.
      final result = (await tester.runAsync(() => preparePhoto(syntheticJpeg(2400, 1800))))!;

      expect(result.width, maxImageEdge);
      expect(result.height, (1800 * maxImageEdge / 2400).round());
      expect(result.bytes, isNotEmpty);
      // It must still be a JPEG — the API is told the media type.
      expect(result.bytes[0], 0xFF);
      expect(result.bytes[1], 0xD8);
    });

    testWidgets('a portrait photo scales on its long edge', (tester) async {
      final result = (await tester.runAsync(() => preparePhoto(syntheticJpeg(1200, 3000))))!;
      expect(result.height, maxImageEdge);
      expect(result.width, (1200 * maxImageEdge / 3000).round());
    });

    testWidgets('an image already within the bound keeps its size', (tester) async {
      final result = (await tester.runAsync(() => preparePhoto(syntheticJpeg(800, 600))))!;
      expect(result.width, 800);
      expect(result.height, 600);
      // Still re-encoded: a huge PNG of a small bottle costs the same upload
      // time as a large photograph.
      expect(result.bytes, isNotEmpty);
    });

    testWidgets('the token estimate follows the resized dimensions',
        (tester) async {
      final result = (await tester.runAsync(() => preparePhoto(syntheticJpeg(2400, 1800))))!;
      expect(result.approximateTokens,
          (result.width * result.height / 750).round());
      // The whole point of resizing: an unresized 2400x1800 would be ~5,760.
      expect(result.approximateTokens, lessThan(3000));
    });

    testWidgets('a square photo scales both axes to the bound', (tester) async {
      final result = (await tester.runAsync(() => preparePhoto(syntheticJpeg(3000, 3000))))!;
      expect(result.width, maxImageEdge);
      expect(result.height, maxImageEdge);
    });
  });

  group('the fit geometry', () {
    test('leaves a small image alone', () {
      expect(fitWithinForTest(800, 600, 1568), (800, 600));
    });

    test('scales the long edge to the limit', () {
      expect(fitWithinForTest(3136, 1568, 1568), (1568, 784));
      expect(fitWithinForTest(1568, 3136, 1568), (784, 1568));
    });

    test('never rounds an axis to zero', () {
      // A very wide, very short panorama scaled naively rounds its short edge
      // to 0, and a zero-height codec target throws rather than producing a
      // picture.
      final (w, h) = fitWithinForTest(20000, 3, 1568);
      expect(w, 1568);
      expect(h, greaterThanOrEqualTo(1));
    });

    test('degenerate input does not throw', () {
      expect(fitWithinForTest(0, 0, 1568), (1, 1));
    });
  });
}
