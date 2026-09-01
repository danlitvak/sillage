import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/taste.dart';
import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// What the collection says about how its owner buys.
///
/// Every figure on this screen is computed in `lib/core/taste.dart` from the
/// note pyramids, and every one is reproducible in a test with a hand-computed
/// expected value. Nothing here is a model's opinion.
class TasteScreen extends ConsumerWidget {
  const TasteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(tasteProfileProvider);
    final collection = ref.watch(collectionProvider);

    return SafeArea(
      bottom: false,
      child: profile.when(
        loading: () => const Center(child: BusyBar()),
        error: (e, _) => EmptyState(title: 'Could not compute', detail: '$e'),
        data: (p) {
          if (p.itemCount == 0) {
            return const EmptyState(
              title: 'Nothing to read yet',
              detail: 'Add a few bottles and patterns appear here.',
            );
          }

          final items = collection.valueOrNull ?? const [];

          return ListView(
            padding: const EdgeInsets.all(Space.lg),
            children: [
              Text('Taste', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: Space.xl),

              if (!p.hasEnoughForPatterns)
                Container(
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(
                    border: Border.all(color: SillageTokens.of(context).border),
                    borderRadius: squareRadius,
                  ),
                  child: Text(
                    // Says why there is nothing rather than showing a pattern
                    // derived from three bottles. "100% designer" about two
                    // bottles is noise dressed as insight.
                    'Patterns need at least '
                    '${TasteThresholds.minimumCollectionForPatterns} bottles. '
                    'You have ${p.itemCount}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else ...[
                const SectionHeading('Patterns'),
                for (final pattern in p.patterns) ...[
                  _PatternCard(pattern: pattern),
                  const SizedBox(height: Space.sm),
                ],
              ],

              const SizedBox(height: Space.xl),
              const SectionHeading('Houses'),
              _BarList(
                entries: (p.houseCounts.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                    .take(8)
                    .map((e) => (
                          _houseName(items, e.key),
                          e.value.toDouble(),
                          '${e.value}',
                        ))
                    .toList(),
                max: p.itemCount.toDouble(),
              ),

              const SizedBox(height: Space.xl),
              const SectionHeading('Kind of house'),
              _BarList(
                entries: (p.tierCounts.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                    .map((e) => (e.key.label, e.value.toDouble(), '${e.value}'))
                    .toList(),
                max: p.itemCount.toDouble(),
              ),

              const SizedBox(height: Space.xl),
              const SectionHeading('Notes you keep buying'),
              _BarList(
                entries: (p.noteFrequency.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value)))
                    .take(10)
                    .map((e) => (
                          _noteName(items, e.key),
                          e.value,
                          '${(e.value * 100).round()}%',
                        ))
                    .toList(),
                max: 1,
              ),

              const SizedBox(height: Space.xl),
              const SectionHeading('Where the data came from'),
              Text(
                p.unverifiedCount == 0
                    ? 'Every pyramid on your shelf has been confirmed.'
                    : '${p.unverifiedCount} of ${p.itemCount} pyramids are '
                        'model-proposed and unconfirmed. Everything above is '
                        'computed from them.',
                style: Theme.of(context).textTheme.bodySmall,
              ),

              const BottomGutter(barHeight: 60),
            ],
          );
        },
      ),
    );
  }

  String _houseName(List<CollectionItem> items, String key) =>
      items
          .where((i) => i.fragrance.brand.key == key)
          .map((i) => i.fragrance.brand.displayName)
          .firstOrNull ??
      key;

  String _noteName(List<CollectionItem> items, String key) =>
      items
          .expand((i) => i.fragrance.notes)
          .where((n) => n.key == key)
          .map((n) => n.displayName)
          .firstOrNull ??
      key;
}

class _PatternCard extends StatelessWidget {
  const _PatternCard({required this.pattern});
  final TastePattern pattern;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    // The data-honesty pattern is drawn differently: it qualifies everything
    // above it rather than describing the collection.
    final isCaveat = pattern.kind == PatternKind.unverifiedData;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        border: Border.all(
            color: isCaveat ? tokens.borderStrong : tokens.border),
        color: isCaveat ? tokens.surface : Colors.transparent,
        borderRadius: squareRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(pattern.headline,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Space.xs),
          Text(pattern.detail, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// A labelled bar list. Bars are proportions of [max], so two lists on the same
/// screen cannot imply a comparison that is not there.
class _BarList extends StatelessWidget {
  const _BarList({required this.entries, required this.max});

  final List<(String, double, String)> entries;
  final double max;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    if (entries.isEmpty) {
      return Text('Nothing yet.', style: Theme.of(context).textTheme.bodySmall);
    }

    return Column(
      children: [
        for (final (label, value, display) in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: Container(
                    height: 8,
                    color: tokens.surface,
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: max <= 0 ? 0 : (value / max).clamp(0.0, 1.0),
                      child: ColoredBox(color: tokens.foreground),
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    display,
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
