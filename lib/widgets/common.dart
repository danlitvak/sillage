/// Shared house-style widgets.
///
/// Each one exists because `Dev/DESIGN.md` names the mistake it avoids. The
/// rules are cited where they apply rather than summarised here.
library;

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../theme/theme.dart';

/// Whether the platform asked for reduced motion.
///
/// Checked rather than assumed — every animation in this app is gated on it,
/// and each has a static fallback that still reads.
bool reducedMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

// =============================================================================

/// A bordered chip at tap height with a real icon.
///
/// DESIGN.md, "No `← Text` links": an arrow glyph renders at a different weight
/// and baseline in every font and, beside a proper icon set, reads as one that
/// failed to load. An underlined run of text is also a 16px target.
class BackChip extends StatelessWidget {
  const BackChip({super.key, this.onPressed, this.label = 'Back'});

  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onPressed ?? () => Navigator.of(context).maybePop(),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          decoration: BoxDecoration(
            border: Border.all(color: tokens.border),
            borderRadius: squareRadius,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chevron_left, size: 18, color: tokens.foreground),
              const SizedBox(width: Space.xs),
              Text(label, style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================

/// A busy indicator that signals by MOTION, not brightness.
///
/// DESIGN.md, "Busy states signal by motion": a static hairline is invisible on
/// a control that is already dimmed, a spinner glyph needs horizontal room a
/// narrow button does not have, and a glowing sweep is added light that has to
/// be re-tuned for every theme.
///
/// So: a short bar travelling an edge, drawn in `currentColor` so it inverts
/// correctly on filled and bordered controls alike, with a static full-width
/// rule as the reduced-motion fallback.
class BusyBar extends StatefulWidget {
  const BusyBar({super.key, this.height = 2});

  final double height;

  @override
  State<BusyBar> createState() => _BusyBarState();
}

class _BusyBarState extends State<BusyBar> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  /// The controller is started HERE rather than at construction, because
  /// `reducedMotion` needs a context.
  ///
  /// Starting it unconditionally and merely declining to draw the moving part
  /// would leave a 1.1s loop ticking forever — burning a frame's worth of work
  /// every vsync, on precisely the devices whose users asked for less of that.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reducedMotion(context)) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colour = DefaultTextStyle.of(context).style.color ??
        SillageTokens.of(context).foreground;

    if (reducedMotion(context)) {
      // The static fallback still reads as "busy" because it is drawn at all —
      // it is not present when idle.
      return Container(height: widget.height, color: colour.withValues(alpha: 0.4));
    }

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final barWidth = width * 0.3;
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              // Eased rather than linear, so the bar accelerates away and
              // decelerates in instead of sliding at constant velocity.
              // DESIGN.md: "Motion must feel physical, never linear".
              final t = Curves.easeInOutCubic.transform(_controller.value);
              return Stack(
                children: [
                  Positioned(
                    left: (width + barWidth) * t - barWidth,
                    width: barWidth,
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(color: colour),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// =============================================================================

/// Marks a fact as model-proposed and unconfirmed.
///
/// Not decoration. Every recommendation the app makes is computed from note
/// pyramids, so whether a pyramid has been confirmed by a human changes how
/// much weight a reader should give everything downstream of it.
class ProvenanceBadge extends StatelessWidget {
  const ProvenanceBadge({super.key, required this.source});

  final Provenance source;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    final (label, filled) = switch (source) {
      Provenance.model => ('UNVERIFIED', false),
      Provenance.brand => ('FROM THE HOUSE', false),
      Provenance.user => ('CONFIRMED', true),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: filled ? tokens.foreground : tokens.borderStrong),
        color: filled ? tokens.foreground : Colors.transparent,
        borderRadius: squareRadius,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: filled ? tokens.background : tokens.mutedForeground,
              fontSize: 10,
            ),
      ),
    );
  }
}

// =============================================================================

/// A section heading in the mono face.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

// =============================================================================

/// An empty state that says what to do, without explaining what a control does.
///
/// DESIGN.md, "Nothing over-explained".
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.detail,
    this.action,
  });

  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (detail != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: tokens.mutedForeground),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: Space.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================

/// Reserves the bottom bar's height plus the safe-area inset PLUS a gutter.
///
/// DESIGN.md, "always room at the bottom": a last control flush against a fixed
/// bar reads as the page having been cut off rather than ended. One shared
/// widget so the rule cannot be applied inconsistently.
class BottomGutter extends StatelessWidget {
  const BottomGutter({super.key, this.barHeight = 0});

  final double barHeight;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: barHeight +
            MediaQuery.of(context).padding.bottom +
            Space.bottomBarGutter,
      );
}

// =============================================================================

/// The note pyramid, grouped by tier.
///
/// Tiers are labelled and ordered top → heart → base, which is how houses
/// publish them and how a wearer experiences them.
class NotePyramid extends StatelessWidget {
  const NotePyramid({super.key, required this.notes});

  final List<NoteRef> notes;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    if (notes.isEmpty) {
      return Text(
        'No notes recorded yet.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final tier in NoteTier.values)
          if (notes.any((n) => n.tier == tier)) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: Space.sm, top: Space.md),
              child: Text(
                switch (tier) {
                  NoteTier.top => 'TOP',
                  NoteTier.heart => 'HEART',
                  NoteTier.base => 'BASE',
                },
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                for (final note in notes.where((n) => n.tier == tier).toList()
                  ..sort((a, b) => a.position.compareTo(b.position)))
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.md,
                      vertical: Space.sm,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: tokens.border),
                      borderRadius: squareRadius,
                    ),
                    child: Text(
                      note.displayName,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: tokens.foreground,
                          ),
                    ),
                  ),
              ],
            ),
          ],
      ],
    );
  }
}

// =============================================================================

/// Two-step confirmation for anything that cannot be undone.
///
/// DESIGN.md, "Nothing irreversible on one tap": the dialog names WHAT ACTUALLY
/// CHANGES rather than warning in the abstract, because nobody can evaluate a
/// generic "Are you sure?" and so it gets clicked through.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String whatChanges,
  required String confirmLabel,
}) async {
  final tokens = SillageTokens.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      content: Text(whatChanges, style: Theme.of(context).textTheme.bodyMedium),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: tokens.destructive),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

// =============================================================================

/// One tab in [SillageTabBar].
class TabSpec {
  const TabSpec({required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

/// The bottom tab bar.
///
/// Public rather than private to the shell so the rule it exists to enforce is
/// directly testable — see `test/viewport_test.dart`.
///
/// DESIGN.md, "Navigation never hides its own items": equal `flex: 1` cells
/// divide whatever width exists, and the LABEL is dropped before the icon at
/// narrow widths while surviving as the accessible name. Never
/// `overflow-x: auto` — a bar that looks like a complete set and is actually a
/// filmstrip is worse than short labels.
class SillageTabBar extends StatelessWidget {
  const SillageTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
  });

  final List<TabSpec> tabs;
  final int selectedIndex;

  /// Below this per-cell width the label is dropped.
  ///
  /// Measured against the real thing rather than taken off a breakpoint scale:
  /// an icon plus a 10px mono label needs roughly this much not to clip.
  static const minWidthPerCellForLabel = 76.0;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tokens.border)),
        color: tokens.background,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showLabels = tabs.isNotEmpty &&
                  constraints.maxWidth / tabs.length >= minWidthPerCellForLabel;
              return Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Expanded(
                      child: _NavCell(
                        spec: tabs[i],
                        selected: i == selectedIndex,
                        showLabel: showLabels,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NavCell extends StatelessWidget {
  const _NavCell({
    required this.spec,
    required this.selected,
    required this.showLabel,
  });

  final TabSpec spec;
  final bool selected;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    final colour = selected ? tokens.foreground : tokens.mutedForeground;

    return Semantics(
      button: true,
      selected: selected,
      // The label survives as the accessible name even when it is not drawn.
      label: spec.label,
      child: InkWell(
        onTap: spec.onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(spec.icon, size: 22, color: colour),
            if (showLabel) ...[
              const SizedBox(height: 2),
              Text(
                spec.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: colour, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
