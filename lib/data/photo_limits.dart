/// The image bounds, kept free of any Flutter dependency.
///
/// Split out of `photo.dart` because that file decodes through `dart:ui`, which
/// is unavailable to a plain `dart run` script — and `tool/eval_identify.dart`
/// must resize photographs to EXACTLY the same bounds the app uses, or it
/// measures a path no user ever takes (and bills several times the tokens: an
/// untouched 813 KB photo cost 4,974 input tokens against 884 for a resized
/// one).
///
/// One definition, two consumers, no chance of drift.
library;

/// Claude's own ceiling. Beyond this the API downscales anyway, so sending more
/// pays to upload pixels that are discarded on arrival.
const int maxImageEdge = 1568;

/// Visually indistinguishable for label text at this size, and roughly half the
/// payload of quality 95.
const int jpegQuality = 85;
