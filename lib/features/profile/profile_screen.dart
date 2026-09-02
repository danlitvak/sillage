import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/taste.dart';
import '../../providers.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Who you are, what your shelf adds up to, and the way out.
///
/// =============================================================================
/// THE GAP THIS FILLS FIRST
/// =============================================================================
/// Until this screen existed there was **no way to sign out of the app at all**.
/// On a shared laptop that is not a missing nicety, it is a defect — and it went
/// unnoticed because every test and every manual pass started from an account
/// that was already signed in.
///
/// The rest of the screen is the summary a collector actually wants: how many
/// bottles, how many houses, what they gravitate to. It reads the SAME
/// `TasteProfile` the Taste tab does rather than recomputing anything, so the
/// two screens cannot disagree about the same shelf.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _name = TextEditingController();
  bool _editing = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).updateDisplayName(_name.text);
      ref.invalidate(profileProvider);
      if (mounted) setState(() => _editing = false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Builds the link from the page's own origin, so it is correct on every
  /// deployment (and on localhost) without a hardcoded domain to go stale.
  String _shareUrl(String slug) => '${Uri.base.origin}/#/s/$slug';

  Future<void> _toggleSharing(bool on) async {
    setState(() => _saving = true);
    final repo = ref.read(repositoryProvider);
    try {
      if (on) {
        await repo.shareShelf();
      } else {
        await repo.unshareShelf();
      }
      ref.invalidate(shareSlugProvider);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copy(String slug) async {
    await Clipboard.setData(ClipboardData(text: _shareUrl(slug)));
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('Link copied'),
          duration: Duration(seconds: 2),
          margin: EdgeInsets.fromLTRB(
              Space.lg, 0, Space.lg, 60 + Space.bottomBarGutter),
        ));
    }
  }

  Future<void> _signOut() async {
    // DESIGN.md, "Nothing irreversible on one tap" — and it names what
    // survives, because the thing people actually fear is losing the shelf.
    final confirmed = await confirmDestructive(
      context,
      title: 'Sign out?',
      whatChanges:
          'Your shelf stays exactly as it is and comes back when you sign in '
          'again. You will need your password to get back in — there is no '
          'reset yet.',
      confirmLabel: 'Sign out',
    );
    if (!confirmed) return;
    await ref.read(repositoryProvider).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    final profile = ref.watch(profileProvider);
    final taste = ref.watch(tasteProfileProvider).valueOrNull;
    final items = ref.watch(collectionProvider).valueOrNull ?? const [];
    final email = ref.read(repositoryProvider).email;

    final displayName = profile.valueOrNull?['display_name'] as String?;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Text('You', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: Space.xl),

          // ------------------------------------------------------------- name
          const SectionHeading('Name'),
          if (_editing) ...[
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Display name'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: const Text('Save'),
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _saving ? null : () => setState(() => _editing = false),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
            if (_saving) const BusyBar(),
          ] else
            _Row(
              label: displayName ?? 'Not set',
              muted: displayName == null,
              trailing: TextButton(
                onPressed: () {
                  _name.text = displayName ?? '';
                  setState(() => _editing = true);
                },
                child: Text(displayName == null ? 'Add' : 'Edit'),
              ),
            ),

          if (email != null) ...[
            const SizedBox(height: Space.lg),
            const SectionHeading('Signed in as'),
            _Row(label: email),
          ],

          // ------------------------------------------------------------ stats
          const SizedBox(height: Space.xl),
          const SectionHeading('Your shelf'),
          if (taste == null || taste.itemCount == 0)
            Text('Nothing on the shelf yet.',
                style: Theme.of(context).textTheme.bodySmall)
          else
            _Stats(profile: taste, items: items),

          // ------------------------------------------------------------ share
          const SizedBox(height: Space.xl),
          const SectionHeading('Share your shelf'),
          _Sharing(
            slug: ref.watch(shareSlugProvider).valueOrNull,
            busy: _saving,
            url: _shareUrl,
            onToggle: _toggleSharing,
            onCopy: _copy,
          ),

          // ----------------------------------------------------------- signout
          const SizedBox(height: Space.xxl),
          OutlinedButton(
            onPressed: _signOut,
            style: OutlinedButton.styleFrom(
              foregroundColor: tokens.destructive,
              side: BorderSide(color: tokens.destructive),
            ),
            child: const Text('Sign out'),
          ),
          const BottomGutter(barHeight: 60),
        ],
      ),
    );
  }
}

/// A label with an optional trailing control, at a consistent height.
class _Row extends StatelessWidget {
  const _Row({required this.label, this.trailing, this.muted = false});

  final String label;
  final Widget? trailing;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Space.lg, vertical: Space.sm),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.border),
        borderRadius: squareRadius,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted
                  ? Theme.of(context).textTheme.bodySmall
                  : Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// The shelf in numbers.
///
/// Every figure comes off the same [TasteProfile] the Taste tab renders, so the
/// two can never disagree about one shelf.
class _Stats extends StatelessWidget {
  const _Stats({required this.profile, required this.items});

  final TasteProfile profile;
  final List<CollectionItem> items;

  @override
  Widget build(BuildContext context) {
    final topHouse = profile.topHouse;
    final houseName = topHouse == null
        ? null
        : items
            .where((i) => i.fragrance.brand.key == topHouse.key)
            .map((i) => i.fragrance.brand.displayName)
            .firstOrNull;

    final topNote = (profile.noteFrequency.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .firstOrNull;
    final noteName = topNote == null
        ? null
        : items
            .expand((i) => i.fragrance.notes)
            .where((n) => n.key == topNote.key)
            .map((n) => n.displayName)
            .firstOrNull;

    final rated = items.where((i) => i.rating != null).toList();
    final averageRating = rated.isEmpty
        ? null
        : rated.map((i) => i.rating!).reduce((a, b) => a + b) / rated.length;

    return Column(
      children: [
        _Stat(label: 'Bottles', value: '${profile.itemCount}'),
        _Stat(label: 'Houses', value: '${profile.houseCounts.length}'),
        if (houseName != null)
          _Stat(label: 'Most of', value: '$houseName (${topHouse!.value})'),
        if (noteName != null)
          _Stat(
            label: 'Signature note',
            value: '$noteName (${(topNote!.value * 100).round()}%)',
          ),
        if (averageRating != null)
          _Stat(
            label: 'Average rating',
            value: averageRating.toStringAsFixed(1),
          ),
        if (profile.cloneCount > 0)
          _Stat(label: 'Dupes', value: '${profile.cloneCount}'),
        // Stated here as well as on the Taste tab: the numbers above are
        // computed from note pyramids, and how many of those a human has
        // checked changes how much they are worth.
        _Stat(
          label: 'Verified pyramids',
          value: '${profile.itemCount - profile.unverifiedCount}'
              ' of ${profile.itemCount}',
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Text(
            value,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: tokens.foreground),
          ),
        ],
      ),
    );
  }
}

/// The sharing control.
///
/// Off by default and revocable, and the copy says exactly what turning it on
/// exposes — a link that needs no account is the kind of thing someone should
/// understand before they create one, not after.
class _Sharing extends StatelessWidget {
  const _Sharing({
    required this.slug,
    required this.busy,
    required this.url,
    required this.onToggle,
    required this.onCopy,
  });

  final String? slug;
  final bool busy;
  final String Function(String) url;
  final Future<void> Function(bool) onToggle;
  final Future<void> Function(String) onCopy;

  @override
  Widget build(BuildContext context) {
    final tokens = SillageTokens.of(context);
    final on = slug != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Space.lg, vertical: Space.sm),
          decoration: BoxDecoration(
            border: Border.all(color: tokens.border),
            borderRadius: squareRadius,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  on ? 'Anyone with the link can view' : 'Private',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Switch(
                value: on,
                onChanged: busy ? null : onToggle,
                activeThumbColor: tokens.background,
                activeTrackColor: tokens.foreground,
              ),
            ],
          ),
        ),
        if (busy) const BusyBar(),

        const SizedBox(height: Space.sm),
        Text(
          on
              // Explains what the reader cannot infer: the shape of the
              // exposure, and that revoking is real. Not a description of the
              // switch — DESIGN.md, "nothing over-explained".
              ? 'Your bottles, notes and ratings are visible to anyone holding '
                  'this link, without an account. Your photos, your private '
                  'notes and your email are not. Turning this off kills the '
                  'link for good — turning it back on makes a new one.'
              : 'Your shelf is visible only to you.',
          style: Theme.of(context).textTheme.bodySmall,
        ),

        if (on) ...[
          const SizedBox(height: Space.md),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              border: Border.all(color: tokens.border),
              color: tokens.surface,
              borderRadius: squareRadius,
            ),
            child: SelectableText(
              url(slug!),
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
            ),
          ),
          const SizedBox(height: Space.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => onCopy(slug!),
              child: const Text('Copy link'),
            ),
          ),
        ],
      ],
    );
  }
}
