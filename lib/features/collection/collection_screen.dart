import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// The shelf: every bottle owned, shown as the user's OWN photograph.
///
/// Their photo rather than a stock image — it makes the shelf recognisably
/// theirs, and it sidesteps the licensing problem that stock bottle imagery
/// would create.
class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collection = ref.watch(collectionProvider);

    return SafeArea(
      bottom: false,
      child: collection.when(
        loading: () => const Center(child: BusyBar()),
        error: (e, _) => EmptyState(
          title: 'Could not load your shelf',
          detail: '$e',
          action: OutlinedButton(
            onPressed: () => ref.invalidate(collectionProvider),
            child: const Text('Try again'),
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return EmptyState(
              title: 'Nothing on the shelf yet',
              detail: 'Photograph a bottle and it lands here.',
              action: FilledButton(
                onPressed: () => context.go('/scan'),
                child: const Text('Scan a bottle'),
              ),
            );
          }

          final owned = items.where((i) => i.status != OwnershipStatus.want).toList();
          final wanted = items.where((i) => i.status == OwnershipStatus.want).toList();

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(collectionProvider);
              ref.invalidate(catalogProvider);
            },
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                      Space.lg, Space.lg, Space.lg, Space.sm),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('Shelf',
                            style: Theme.of(context).textTheme.headlineMedium),
                        const SizedBox(width: Space.sm),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '${owned.length}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _grid(context, ref, owned),
                if (wanted.isNotEmpty) ...[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                        Space.lg, Space.xl, Space.lg, Space.sm),
                    sliver: SliverToBoxAdapter(
                      child: SectionHeading('Want (${wanted.length})'),
                    ),
                  ),
                  _grid(context, ref, wanted),
                ],
                const SliverToBoxAdapter(child: BottomGutter(barHeight: 60)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _grid(BuildContext context, WidgetRef ref, List<CollectionItem> items) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          // Column count derived from the real width rather than a breakpoint
          // constant, so it is right at every size including a resized desktop
          // window. DESIGN.md: "works at every width".
          final width = constraints.crossAxisExtent;
          final columns = (width / 180).floor().clamp(2, 6);
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: Space.md,
              crossAxisSpacing: Space.md,
              childAspectRatio: 0.72,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => _BottleTile(item: items[index]),
              childCount: items.length,
            ),
          );
        },
      ),
    );
  }
}

class _BottleTile extends ConsumerWidget {
  const _BottleTile({required this.item});

  final CollectionItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = SillageTokens.of(context);
    final photoPath = item.photoPath;
    final url = photoPath == null
        ? null
        : ref.read(repositoryProvider).publicPhotoUrl(photoPath);

    return InkWell(
      onTap: () => context.push('/fragrance/${item.fragrance.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: tokens.border),
                color: tokens.surface,
                borderRadius: squareRadius,
              ),
              child: url == null
                  ? Center(
                      child: Icon(Icons.local_drink_outlined,
                          color: tokens.borderStrong, size: 32),
                    )
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, _) => Center(
                        child: Icon(Icons.local_drink_outlined,
                            color: tokens.borderStrong, size: 32),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: Space.sm),
          Text(
            item.fragrance.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  item.fragrance.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              // The unverified mark is carried all the way to the tile: it
              // changes how much weight to give everything computed from these
              // notes, so it should not be buried on the detail screen.
              if (item.fragrance.notesUnverified)
                Icon(Icons.help_outline, size: 13, color: tokens.mutedForeground),
            ],
          ),
        ],
      ),
    );
  }
}
