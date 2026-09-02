import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/identity.dart';
import '../../core/models.dart';
import '../../core/taste.dart';
import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Somebody else's shelf, opened from a link.
///
/// =============================================================================
/// THIS SCREEN HAS NO SESSION
/// =============================================================================
/// It renders for a visitor who has never signed in, which makes it the only
/// screen in the app that must not touch `collectionProvider`, the catalog, or
/// anything else behind RLS. Everything it draws comes from the single
/// `get_shared_shelf` call, and if that returns null it says so plainly rather
/// than bouncing the visitor to a login wall.
///
/// The patterns are computed HERE with the same `buildTasteProfile` the owner's
/// own Taste tab uses, over statistics built from the shared items alone. The
/// detectors that matter for a shelf — houses, note frequency, dupe share — are
/// counts and proportions, so they are correct over any set; only the IDF-based
/// centroid would be degenerate on a set this small, and nothing here reads it.
class SharedShelfScreen extends ConsumerWidget {
  const SharedShelfScreen({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shelf = ref.watch(sharedShelfProvider(slug));

    return Scaffold(
      body: SafeArea(
        child: shelf.when(
          loading: () => const Center(child: BusyBar()),
          error: (e, _) => const EmptyState(
            title: 'Could not load that shelf',
            detail: 'Check the link and try again.',
          ),
          data: (data) {
            if (data == null) {
              // One message for "never existed" and "revoked", because the
              // function deliberately cannot tell them apart — and neither
              // should this screen.
              return const EmptyState(
                title: 'This shelf is not shared',
                detail:
                    'The link may have been turned off, or it was never a link '
                    'to a shelf.',
              );
            }
            return _Shelf(data: data);
          },
        ),
      ),
    );
  }
}

class _Shelf extends StatelessWidget {
  const _Shelf({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final name = data['display_name'] as String?;
    final items = _itemsFrom(data);
    final stats = CatalogStats.from(items.map((i) => i.fragrance));
    final profile = buildTasteProfile(items: items, stats: stats);

    final owned =
        items.where((i) => i.status != OwnershipStatus.want).toList();
    final wanted =
        items.where((i) => i.status == OwnershipStatus.want).toList();

    return ListView(
      padding: const EdgeInsets.all(Space.lg),
      children: [
        Text(
          name == null || name.trim().isEmpty ? 'A shelf' : "$name's shelf",
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: Space.xs),
        Text(
          '${owned.length} ${owned.length == 1 ? 'bottle' : 'bottles'}'
          '${wanted.isEmpty ? '' : ' · ${wanted.length} on the wishlist'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),

        if (profile.patterns.isNotEmpty) ...[
          const SizedBox(height: Space.xl),
          const SectionHeading('How they buy'),
          for (final p in profile.patterns)
            if (p.kind != PatternKind.unverifiedData) ...[
              _Pattern(headline: p.headline, detail: p.detail),
              const SizedBox(height: Space.sm),
            ],
        ],

        const SizedBox(height: Space.xl),
        SectionHeading('The shelf (${owned.length})'),
        for (final item in owned) _Bottle(item: item),

        if (wanted.isNotEmpty) ...[
          const SizedBox(height: Space.xl),
          SectionHeading('Wants (${wanted.length})'),
          for (final item in wanted) _Bottle(item: item),
        ],

        const SizedBox(height: Space.xl),
        Text(
          'Shared from sillage.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const BottomGutter(),
      ],
    );
  }

  /// Rebuilds domain models from the shared JSON.
  ///
  /// Separate from `mapping.dart` because the shape is genuinely different: the
  /// share function returns a flattened, reduced projection rather than the
  /// PostgREST row the app reads for its own shelf. Reusing the row mapper here
  /// would mean widening it to accept a shape that only exists on this screen.
  static List<CollectionItem> _itemsFrom(Map<String, dynamic> data) {
    final raw = (data['items'] as List? ?? const []);
    final out = <CollectionItem>[];

    for (final entry in raw) {
      if (entry is! Map) continue;
      final m = entry.cast<String, dynamic>();

      final notes = <NoteRef>[];
      for (final n in (m['notes'] as List? ?? const [])) {
        if (n is! Map) continue;
        notes.add(NoteRef(
          key: n['key'] as String? ?? '',
          displayName: n['display_name'] as String? ?? '',
          tier: NoteTier.fromWire(n['tier'] as String?),
          position: (n['position'] as num?)?.toInt() ?? 0,
          family: n['family'] as String?,
        ));
      }

      final accords = <AccordRef>[];
      for (final a in (m['accords'] as List? ?? const [])) {
        if (a is! Map) continue;
        accords.add(AccordRef(
          key: a['key'] as String? ?? '',
          displayName: a['display_name'] as String? ?? '',
          weight: (a['weight'] as num?)?.toDouble() ?? 1.0,
        ));
      }

      final brandKey = m['brand_key'] as String? ?? '';
      final fragrance = Fragrance(
        id: m['fragrance_id'] as String? ?? '',
        key: FragranceKey(
          brand: brandKey,
          name: m['display_name'] as String? ?? '',
          concentration: Concentration.fromWire(m['concentration'] as String?),
        ),
        displayName: m['display_name'] as String? ?? '',
        brand: Brand(
          key: brandKey,
          displayName: m['brand_name'] as String? ?? brandKey,
          tier: BrandTier.fromWire(m['brand_tier'] as String?),
        ),
        notes: notes,
        accords: accords,
        releaseYear: (m['release_year'] as num?)?.toInt(),
        // The share payload carries a boolean rather than the original's id —
        // a viewer has no business resolving it — so any non-null stands in.
        cloneOfId: m['is_clone'] == true ? 'shared' : null,
        notesSource: Provenance.fromWire(m['notes_source'] as String?),
      );

      out.add(CollectionItem(
        id: m['id'] as String? ?? '',
        fragrance: fragrance,
        status: OwnershipStatus.fromWire(m['status'] as String?),
        rating: (m['rating'] as num?)?.toDouble(),
      ));
    }
    return out;
  }
}

class _Pattern extends StatelessWidget {
  const _Pattern({required this.headline, required this.detail});

  final String headline;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.border),
        borderRadius: squareRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Space.xs),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Bottle extends StatelessWidget {
  const _Bottle({required this.item});

  final CollectionItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    final f = item.fragrance;
    final rating = item.rating;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Space.sm),
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
                child: Text(f.displayName,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (rating != null && rating > 0) ...[
                const SizedBox(width: Space.sm),
                Text(rating.toStringAsFixed(1),
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(f.subtitle,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              if (f.isClone)
                Text('DUPE',
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(fontSize: 10)),
            ],
          ),
          if (f.notes.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                for (final note in f.notes.take(6))
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Space.sm, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: tokens.border),
                      borderRadius: squareRadius,
                    ),
                    child: Text(
                      note.displayName,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(fontSize: 10),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
