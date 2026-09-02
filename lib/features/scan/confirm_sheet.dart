/// The confirm sheet — where an ambiguous photograph becomes one catalog row.
///
/// =============================================================================
/// THIS SCREEN IS THE POINT OF THE WHOLE IDENTIFY DESIGN
/// =============================================================================
/// A fragrance house reuses one bottle across its entire line, so a photograph
/// often narrows a bottle to a LINE and no further: Sauvage EDT, EDP, Parfum and
/// Elixir are the same glass with a different cap. `identify` is asked for a
/// ranked shortlist precisely so that ambiguity survives to here rather than
/// being resolved by a coin flip inside a model.
///
/// Three things follow, and each is visible in the layout below:
///
///   1. THE EVIDENCE IS SHOWN. The text the model says it actually read is
///      displayed above the candidates, so the user can see whether an answer
///      came off the label or off the bottle's silhouette. A confident-looking
///      candidate derived from a shape deserves more scepticism, and only the
///      evidence makes that visible.
///   2. NOTHING IS PRESELECTED. DESIGN.md: "nothing bad can happen with just one
///      button click". The user taps the candidate they are holding.
///   3. "NONE OF THESE" IS A FIRST-CLASS OPTION, not a cancel. It records the
///      rejection — the most informative rows in the scans table — and opens
///      manual entry.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/identity.dart';
import '../../data/scan_service.dart';
import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';


/// Returns the DISPLAY NAME of whatever landed on the shelf, or null if the
/// user backed out. The caller uses it to confirm the add — the scan flow ends
/// on the Scan tab, so without a word from here nothing visibly happened.
Future<String?> showConfirmSheet({
  required BuildContext context,
  required WidgetRef ref,
  required ScanResult result,
  required Uint8List photoBytes,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _ConfirmSheet(result: result, photoBytes: photoBytes),
  );
}

class _ConfirmSheet extends ConsumerStatefulWidget {
  const _ConfirmSheet({required this.result, required this.photoBytes});

  final ScanResult result;
  final Uint8List photoBytes;

  @override
  ConsumerState<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends ConsumerState<_ConfirmSheet> {
  bool _saving = false;
  String? _error;

  Future<void> _confirm(ScanCandidate candidate) async {
    setState(() {
      _saving = true;
      _error = null;
    });

    final repo = ref.read(repositoryProvider);
    final scan = ref.read(scanServiceProvider);

    try {
      final fragrance = await scan.resolveToCatalog(candidate);

      String? photoPath;
      try {
        photoPath = await repo.uploadBottlePhoto(
          fileName: '${DateTime.now().millisecondsSinceEpoch}.jpg',
          bytes: widget.photoBytes,
        );
      } catch (_) {
        // A failed upload must not lose the bottle. The row is written without
        // a photo and the tile falls back to a placeholder.
        photoPath = null;
      }

      await repo.addToCollection(
        fragranceId: fragrance.id,
        photoPath: photoPath,
      );
      await repo.recordScan(
        photoPath: photoPath,
        labelText: widget.result.labelText,
        rawResponse: widget.result.raw,
        chosenFragranceId: fragrance.id,
      );

      ref.invalidate(collectionProvider);
      ref.invalidate(catalogProvider);
      ref.read(unseenShelfCountProvider.notifier).increment();
      if (mounted) Navigator.of(context).pop(fragrance.displayName);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save that. $e';
        });
      }
    }
  }

  Future<void> _rejectAll() async {
    // Recorded, not discarded. A scan where every candidate was wrong is the
    // most informative row in the table for improving the prompt.
    await ref.read(repositoryProvider).recordScan(
          labelText: widget.result.labelText,
          rawResponse: widget.result.raw,
          rejected: true,
        );
    if (!mounted) return;
    Navigator.of(context).pop();
    await showManualEntrySheet(context: context, ref: ref);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    final result = widget.result;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Text(
            result.isEmpty ? 'Not sure what this is' : 'Which one is it?',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: Space.lg),

          // ---------------------------------------------------------------
          // THE EVIDENCE. Shown before the candidates, because it is what the
          // candidates are supposed to follow from.
          // ---------------------------------------------------------------
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              border: Border.all(color: tokens.border),
              color: tokens.surface,
              borderRadius: squareRadius,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('READ FROM THE BOTTLE',
                          style: Theme.of(context).textTheme.labelSmall),
                    ),
                    if (!result.legible)
                      Text('NOT LEGIBLE',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: tokens.destructive)),
                  ],
                ),
                const SizedBox(height: Space.sm),
                Text(
                  result.labelText.trim().isEmpty
                      ? 'Nothing legible in the photo.'
                      : result.labelText,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (!result.legible) ...[
                  const SizedBox(height: Space.sm),
                  Text(
                    // Explained because it changes how the candidates below
                    // should be read — not an explanation of a control.
                    'These guesses come from the bottle shape, not the label.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: Space.lg),

          if (result.isEmpty)
            Text(
              'Nothing matched confidently enough to offer. Add it by hand.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            for (final candidate in result.candidates) ...[
              _CandidateTile(
                candidate: candidate,
                enabled: !_saving,
                onTap: () => _confirm(candidate),
              ),
              const SizedBox(height: Space.sm),
            ],

          if (_saving) const Padding(
            padding: EdgeInsets.symmetric(vertical: Space.md),
            child: BusyBar(),
          ),

          if (_error != null) ...[
            const SizedBox(height: Space.md),
            Text(
              _error!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: tokens.destructive),
            ),
          ],

          const SizedBox(height: Space.md),
          OutlinedButton(
            onPressed: _saving ? null : _rejectAll,
            child: Text(result.isEmpty ? 'Add by hand' : 'None of these'),
          ),
          const BottomGutter(),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.candidate,
    required this.enabled,
    required this.onTap,
  });

  final ScanCandidate candidate;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);

    return InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Space.lg),
        decoration: BoxDecoration(
          border: Border.all(color: tokens.border),
          borderRadius: squareRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    candidate.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: Space.sm),
                Text(
                  '${(candidate.confidence * 100).round()}%',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Text(candidate.brand,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: Space.sm),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(
                      // An unread concentration is marked, because it is the
                      // field most often wrong and it changes the pyramid
                      // entirely.
                      color: candidate.concentration == Concentration.unknown
                          ? tokens.borderStrong
                          : tokens.border,
                    ),
                    borderRadius: squareRadius,
                  ),
                  child: Text(
                    candidate.concentration == Concentration.unknown
                        ? 'STRENGTH UNREAD'
                        : candidate.concentration.short,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(fontSize: 10),
                  ),
                ),
              ],
            ),
            if (candidate.reasoning.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              Text(candidate.reasoning,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// MANUAL ENTRY
// =============================================================================

/// Typing a bottle in by hand.
///
/// Always reachable, not only as a fallback: identification declining to guess
/// is a designed outcome, so the path it hands the user to has to be a real
/// screen rather than an apology.
Future<String?> showManualEntrySheet({
  required BuildContext context,
  required WidgetRef ref,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _ManualEntrySheet(),
  );
}

class _ManualEntrySheet extends ConsumerStatefulWidget {
  const _ManualEntrySheet();

  @override
  ConsumerState<_ManualEntrySheet> createState() => _ManualEntrySheetState();
}

class _ManualEntrySheetState extends ConsumerState<_ManualEntrySheet> {
  final _brand = TextEditingController();
  final _name = TextEditingController();
  Concentration _concentration = Concentration.unknown;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _brand.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final brand = _brand.text.trim();
    final name = _name.text.trim();
    if (brand.isEmpty || name.isEmpty) {
      setState(() => _error = 'Both the house and the name are needed.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final scan = ref.read(scanServiceProvider);
      final repo = ref.read(repositoryProvider);
      final fragrance = await scan.resolveToCatalog(ScanCandidate(
        brand: brand,
        name: name,
        concentration: _concentration,
        confidence: 1,
        reasoning: 'Entered by hand.',
      ));
      await repo.addToCollection(fragranceId: fragrance.id);
      ref.invalidate(collectionProvider);
      ref.invalidate(catalogProvider);
      ref.read(unseenShelfCountProvider.notifier).increment();
      if (mounted) Navigator.of(context).pop(fragrance.displayName);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save that. $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Add by hand',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: Space.lg),
            TextField(
              controller: _brand,
              decoration: const InputDecoration(labelText: 'House'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                // Explained because getting it wrong forks the catalog — a
                // consequence the field label cannot carry on its own.
                helperText: 'Without the house. Keep Elixir, Intense and Extreme.',
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: Space.md),
            // The native picker, restyled — on a phone it opens the platform
            // control, which is thumb-sized and accessible for free.
            // DESIGN.md: "Native controls, app chrome".
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Strength'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<Concentration>(
                  value: _concentration,
                  isExpanded: true,
                  icon: Icon(Icons.expand_more, color: tokens.foreground),
                  items: [
                    for (final c in Concentration.values)
                      DropdownMenuItem(value: c, child: Text(c.label)),
                  ],
                  onChanged: (v) =>
                      setState(() => _concentration = v ?? Concentration.unknown),
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            SizedBox(
              width: double.infinity,
              child: Column(
                children: [
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: const Text('Add to shelf'),
                  ),
                  if (_saving) const BusyBar(),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Space.md),
              Text(
                _error!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: tokens.destructive),
              ),
            ],
            const BottomGutter(),
          ],
        ),
      ),
    );
  }
}
