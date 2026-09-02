import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/recommend.dart';
import '../../core/taste.dart';
import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Recommendations, grouped by the strategy that produced them.
///
/// =============================================================================
/// WHY GROUPED AND NOT ONE RANKED LIST
/// =============================================================================
/// The three strategies produce scores that measure different things — a 0.6
/// cosine against the collection centroid and a 0.6 accord-gap score are not
/// comparable quantities. Merging them into one ranked list would imply an
/// ordering the arithmetic does not support.
///
/// Grouping also makes the reason legible before the recommendation is: "because
/// of how you buy" and "fills a gap" are different questions, and a reader can
/// dismiss a whole strategy that is not what they came for.
class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recommendations = ref.watch(recommendationsProvider);
    final profile = ref.watch(tasteProfileProvider).valueOrNull;

    return SafeArea(
      bottom: false,
      child: recommendations.when(
        loading: () => const Center(child: BusyBar()),
        error: (e, _) => EmptyState(
          title: 'Could not build recommendations',
          detail: '$e',
          action: OutlinedButton(
            onPressed: () => ref.invalidate(recommendationsProvider),
            child: const Text('Try again'),
          ),
        ),
        data: (groups) {
          if (profile != null && !profile.hasEnoughForPatterns) {
            final short = TasteThresholds.minimumCollectionForPatterns -
                profile.itemCount;
            return EmptyState(
              title: 'Not enough to go on yet',
              detail:
                  'Recommendations need at least '
                  '${TasteThresholds.minimumCollectionForPatterns} bottles. '
                  'You have ${profile.itemCount}.',
              // A dead end otherwise: the screen states a requirement and
              // offers no way to meet it. The button says how many are left
              // rather than just "scan", so the ask is finite.
              action: FilledButton(
                onPressed: () => context.go('/scan'),
                child: Text(
                  short == 1 ? 'Scan 1 more bottle' : 'Scan $short more bottles',
                ),
              ),
            );
          }

          final nonEmpty = groups.entries.where((e) => e.value.isNotEmpty).toList();
          if (nonEmpty.isEmpty) {
            return EmptyState(
              title: 'Nothing to suggest right now',
              detail: 'Add a few more bottles, or pull to refresh.',
              action: OutlinedButton(
                onPressed: () => ref.invalidate(recommendationsProvider),
                child: const Text('Refresh'),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(recommendationsProvider),
            child: ListView(
              padding: const EdgeInsets.all(Space.lg),
              children: [
                Text('Discover',
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: Space.xl),
                for (final entry in nonEmpty) ...[
                  SectionHeading(entry.key.label),
                  for (final rec in entry.value) ...[
                    _RecommendationCard(rec: rec),
                    const SizedBox(height: Space.sm),
                  ],
                  const SizedBox(height: Space.lg),
                ],
                const BottomGutter(barHeight: 60),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RecommendationCard extends ConsumerWidget {
  const _RecommendationCard({required this.rec});

  final Recommendation rec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = SillageTokens.of(context);

    Future<void> record(String verdict) async {
      await ref.read(repositoryProvider).recordRecommendationFeedback(
            fragranceId: rec.fragrance.id,
            strategy: rec.strategy.wire,
            verdict: verdict,
          );
      ref.invalidate(recommendationsProvider);
      if (verdict == 'saved') ref.invalidate(collectionProvider);
    }

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
          Text(rec.fragrance.displayName,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(rec.fragrance.subtitle,
              style: Theme.of(context).textTheme.bodySmall),

          const SizedBox(height: Space.md),
          // The explanation is built from computed figures, not written by a
          // model — see the header comment in lib/core/recommend.dart.
          Text(rec.explanation, style: Theme.of(context).textTheme.bodyMedium),

          if (rec.drivingNotes.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                for (final note in rec.drivingNotes.take(4))
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Space.sm, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: tokens.border),
                      borderRadius: squareRadius,
                    ),
                    child: Text(
                      note,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(fontSize: 10),
                    ),
                  ),
              ],
            ),
          ],

          if (rec.fragrance.notesUnverified) ...[
            const SizedBox(height: Space.sm),
            Text(
              'Based on unverified notes.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: tokens.mutedForeground),
            ),
          ],

          const SizedBox(height: Space.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => record('saved'),
                  child: const Text('Want'),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: TextButton(
                  onPressed: () => record('dismissed'),
                  child: const Text('Not for me'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
