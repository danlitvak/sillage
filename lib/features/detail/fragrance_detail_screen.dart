import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// One bottle: the photo, the pyramid, where the data came from, and the
/// personal fields.
///
/// Not a tab, so it carries a back control — DESIGN.md, "there should always be
/// a way back from the previous page".
class FragranceDetailScreen extends ConsumerWidget {
  const FragranceDetailScreen({super.key, required this.fragranceId});

  final String fragranceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(collectionProvider);
    final tokens = SillageTokens.of(context);

    return Scaffold(
      body: SafeArea(
        child: collection.when(
          loading: () => const Center(child: BusyBar()),
          error: (e, _) => EmptyState(title: 'Could not load', detail: '$e'),
          data: (items) {
            final item = items
                .where((i) => i.fragrance.id == fragranceId)
                .firstOrNull;
            if (item == null) {
              return const EmptyState(title: 'Not on your shelf');
            }
            final f = item.fragrance;
            final photoPath = item.photoPath;
            final url = photoPath == null
                ? null
                : ref.read(repositoryProvider).publicPhotoUrl(photoPath);

            return ListView(
              padding: const EdgeInsets.all(Space.lg),
              children: [
                const BackChip(),
                const SizedBox(height: Space.lg),

                if (url != null)
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: tokens.border),
                        borderRadius: squareRadius,
                      ),
                      child: Image.network(url, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox()),
                    ),
                  ),
                if (url != null) const SizedBox(height: Space.lg),

                Text(f.displayName,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: Space.xs),
                Text(f.subtitle, style: Theme.of(context).textTheme.bodyMedium),

                const SizedBox(height: Space.md),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    ProvenanceBadge(source: f.notesSource),
                    if (f.brand.tier != BrandTier.unknown)
                      _Chip(f.brand.tier.label),
                    if (f.releaseYear != null) _Chip('${f.releaseYear}'),
                    if (f.isClone) const _Chip('Dupe'),
                  ],
                ),

                if (f.notesUnverified) ...[
                  const SizedBox(height: Space.lg),
                  Container(
                    padding: const EdgeInsets.all(Space.md),
                    decoration: BoxDecoration(
                      border: Border.all(color: tokens.borderStrong),
                      borderRadius: squareRadius,
                    ),
                    child: Text(
                      // A disclosure that is not inferable from the screen, so
                      // it earns its words. DESIGN.md: explain what changes a
                      // conclusion, never what a control does.
                      'These notes were proposed by a model and nobody has '
                      'confirmed them. Your taste profile and every '
                      'recommendation are computed from them.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],

                const SizedBox(height: Space.xl),
                const SectionHeading('Notes'),
                NotePyramid(notes: f.notes),

                if (f.accords.isNotEmpty) ...[
                  const SizedBox(height: Space.xl),
                  const SectionHeading('Accords'),
                  Column(
                    children: [
                      for (final accord in f.accords.toList()
                        ..sort((a, b) => b.weight.compareTo(a.weight)))
                        Padding(
                          padding: const EdgeInsets.only(bottom: Space.sm),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 110,
                                child: Text(accord.displayName,
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                              ),
                              Expanded(
                                child: Container(
                                  height: 6,
                                  color: tokens.surface,
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: accord.weight.clamp(0.0, 1.0),
                                    child: ColoredBox(color: tokens.foreground),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],

                const SizedBox(height: Space.xl),
                const SectionHeading('Yours'),
                _PersonalFields(item: item),

                const SizedBox(height: Space.xxl),
                OutlinedButton(
                  onPressed: () async {
                    final confirmed = await confirmDestructive(
                      context,
                      title: 'Remove from shelf?',
                      // Names what actually changes, including what survives.
                      whatChanges:
                          '${f.displayName} leaves your shelf, along with your '
                          'rating and note. The fragrance stays in the catalog, '
                          'and your photo stays in storage.',
                      confirmLabel: 'Remove',
                    );
                    if (!confirmed || !context.mounted) return;
                    await ref
                        .read(repositoryProvider)
                        .removeFromCollection(item.id);
                    ref.invalidate(collectionProvider);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: tokens.destructive,
                    side: BorderSide(color: tokens.destructive),
                  ),
                  child: const Text('Remove from shelf'),
                ),
                const BottomGutter(),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.border),
        borderRadius: squareRadius,
      ),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10),
      ),
    );
  }
}

/// Rating, status and note — the fields only the owner can supply.
class _PersonalFields extends ConsumerStatefulWidget {
  const _PersonalFields({required this.item});
  final CollectionItem item;

  @override
  ConsumerState<_PersonalFields> createState() => _PersonalFieldsState();
}

class _PersonalFieldsState extends ConsumerState<_PersonalFields> {
  late double _rating = widget.item.rating ?? 0;
  late OwnershipStatus _status = widget.item.status;

  Future<void> _save() async {
    await ref.read(repositoryProvider).updateCollectionItem(
          widget.item.id,
          rating: _rating,
          status: _status,
        );
    ref.invalidate(collectionProvider);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Rating', style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            Text(
              _rating == 0 ? 'Not rated' : _rating.toStringAsFixed(1),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ],
        ),
        Slider(
          value: _rating,
          max: 10,
          divisions: 20,
          onChanged: (v) => setState(() => _rating = v),
          onChangeEnd: (_) => _save(),
        ),
        const SizedBox(height: Space.sm),
        // Equal cells rather than a scrolling strip — the same rule the bottom
        // nav follows.
        Row(
          children: [
            for (final status in OwnershipStatus.values)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: Space.sm),
                  child: _StatusButton(
                    label: switch (status) {
                      OwnershipStatus.have => 'Have',
                      OwnershipStatus.had => 'Had',
                      OwnershipStatus.want => 'Want',
                    },
                    selected: _status == status,
                    onTap: () {
                      setState(() => _status = status);
                      _save();
                    },
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _StatusButton extends StatelessWidget {
  const _StatusButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
              color: selected ? tokens.foreground : tokens.border),
          color: selected ? tokens.foreground : Colors.transparent,
          borderRadius: squareRadius,
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: selected ? tokens.background : tokens.foreground,
              ),
        ),
      ),
    );
  }
}
