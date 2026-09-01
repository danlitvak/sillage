import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/photo.dart';
import '../../data/scan_service.dart';
import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import 'confirm_sheet.dart';

/// Photograph a bottle, get a shortlist, confirm one.
///
/// =============================================================================
/// WHY THERE IS A GALLERY BUTTON AND NOT JUST A CAMERA
/// =============================================================================
/// Two reasons, one of them structural. Android emulators render a synthetic
/// scene through the camera API, so identification cannot be developed or
/// evaluated on one — the Windows and web targets, which have no camera at all,
/// are this project's development harness and need a file path in.
///
/// The second reason is that users want it anyway: half the bottles anyone
/// wants to log are in photos they already took.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final _picker = ImagePicker();

  Uint8List? _preview;
  PreparedPhoto? _prepared;
  bool _busy = false;
  String? _error;

  /// Whether this platform can open a camera at all.
  ///
  /// `image_picker` has no camera implementation on Windows, Linux or the web,
  /// and asking for one there throws. Checked rather than caught, so the button
  /// simply is not offered instead of failing when tapped.
  ///
  /// Uses `defaultTargetPlatform` rather than `dart:io`'s `Platform`: importing
  /// `dart:io` at all breaks the web build, and web is one of this project's
  /// three targets.
  bool get _hasCamera =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _pick(ImageSource source) async {
    setState(() => _error = null);
    try {
      final file = await _picker.pickImage(
        source: source,
        // A first pass at the picker level — cheap, and it keeps the bytes that
        // reach preparePhoto small enough to decode quickly on a phone.
        maxWidth: 3000,
        maxHeight: 3000,
      );
      if (file == null) return;

      final raw = await file.readAsBytes();
      setState(() {
        _preview = raw;
        _busy = true;
      });

      final prepared = await preparePhoto(raw);
      if (!mounted) return;
      setState(() => _prepared = prepared);

      await _identify(prepared);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not read that photo. $e';
          _busy = false;
        });
      }
    }
  }

  Future<void> _identify(PreparedPhoto photo) async {
    try {
      final result = await ref.read(scanServiceProvider).identify(photo.bytes);
      if (!mounted) return;
      setState(() => _busy = false);

      await showConfirmSheet(
        context: context,
        ref: ref,
        result: result,
        photoBytes: photo.bytes,
      );
      if (mounted) setState(() => _preview = null);
    } on ScanException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Identification failed. $e';
      });
    }
  }

  Future<void> _addByHand() async {
    await showManualEntrySheet(context: context, ref: ref);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);

    return SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Scan', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: Space.xl),

            AspectRatio(
              aspectRatio: 3 / 4,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: tokens.border),
                  color: tokens.surface,
                  borderRadius: squareRadius,
                ),
                child: _preview == null
                    ? Center(
                        child: Icon(Icons.photo_camera_outlined,
                            size: 40, color: tokens.borderStrong),
                      )
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(_preview!, fit: BoxFit.cover),
                          if (_busy)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: DefaultTextStyle(
                                style: TextStyle(color: tokens.foreground),
                                child: const BusyBar(height: 3),
                              ),
                            ),
                        ],
                      ),
              ),
            ),

            const SizedBox(height: Space.lg),

            if (_hasCamera)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : () => _pick(ImageSource.camera),
                  child: const Text('Photograph a bottle'),
                ),
              ),
            if (_hasCamera) const SizedBox(height: Space.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                child: Text(_hasCamera ? 'Choose a photo' : 'Choose a photo of a bottle'),
              ),
            ),
            const SizedBox(height: Space.sm),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _busy ? null : _addByHand,
                child: const Text('Add by hand instead'),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: Space.lg),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  border: Border.all(color: tokens.destructive),
                  borderRadius: squareRadius,
                ),
                child: Text(
                  _error!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: tokens.destructive),
                ),
              ),
            ],

            if (_prepared != null && _error == null) ...[
              const SizedBox(height: Space.lg),
              Text(
                // Explained because the NUMBER is not self-evident and it is
                // what the scan costs. DESIGN.md: explain a number, never a
                // control.
                'Sent at ${_prepared!.width}x${_prepared!.height} '
                '(~${_prepared!.approximateTokens} image tokens).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],

            const BottomGutter(barHeight: 60),
          ],
        ),
      ),
    );
  }
}
