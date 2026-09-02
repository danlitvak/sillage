/// The app shell: theme, routes, and the tab bar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/config.dart';
import 'features/auth/auth_screen.dart';
import 'features/collection/collection_screen.dart';
import 'features/detail/fragrance_detail_screen.dart';
import 'features/discover/discover_screen.dart';
import 'features/scan/scan_screen.dart';
import 'features/taste/taste_screen.dart';
import 'main.dart';
import 'providers.dart';
import 'theme/theme.dart';
import 'widgets/common.dart';

class SillageApp extends ConsumerWidget {
  const SillageApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Config.isConfigured) return const MisconfiguredApp();

    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'sillage',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      routerConfig: router,
    );
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/collection',
    redirect: (context, state) {
      final signedIn = ref.read(currentUserProvider) != null;
      final atAuth = state.matchedLocation == '/auth';
      if (!signedIn) return atAuth ? null : '/auth';
      if (atAuth) return '/collection';
      return null;
    },
    // Rebuilds the redirect when auth changes, so signing in navigates without
    // the user tapping anything.
    refreshListenable: _AuthRefresh(ref),
    routes: [
      GoRoute(path: '/auth', builder: (_, _) => const AuthScreen()),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
              path: '/collection',
              builder: (_, _) => const _Opaque(child: CollectionScreen())),
          GoRoute(
              path: '/scan', builder: (_, _) => const _Opaque(child: ScanScreen())),
          GoRoute(
              path: '/taste',
              builder: (_, _) => const _Opaque(child: TasteScreen())),
          GoRoute(
              path: '/discover',
              builder: (_, _) => const _Opaque(child: DiscoverScreen())),
        ],
      ),
      // Detail is NOT a tab — it is pushed, so it carries a back control.
      // DESIGN.md: "there should always be a way back".
      GoRoute(
        path: '/fragrance/:id',
        builder: (context, state) =>
            FragranceDetailScreen(fragranceId: state.pathParameters['id']!),
      ),
    ],
  );
});

/// Paints the theme background behind a routed page.
///
/// Without this, tab pages are TRANSPARENT. During a route transition go_router
/// keeps both the outgoing and incoming pages in the tree, so two transparent
/// pages render over the same Scaffold background and you read both at once —
/// the content of the tab you left visibly overlapping the one you chose until
/// the animation finishes.
///
/// Making each page opaque fixes it by occlusion, which keeps the transition
/// itself intact: the incoming page simply covers the outgoing one as it
/// arrives, the way a page transition is supposed to look.
class _Opaque extends StatelessWidget {
  const _Opaque({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: SillageTokens.of(context).background,
        child: child,
      );
}

class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen(authStateProvider, (_, _) => notifyListeners());
  }
}

// =============================================================================

/// Tabs, and the one rule that governs them.
const _tabs = [
  (path: '/collection', label: 'Shelf', icon: Icons.grid_view),
  (path: '/scan', label: 'Scan', icon: Icons.photo_camera_outlined),
  (path: '/taste', label: 'Taste', icon: Icons.insights_outlined),
  (path: '/discover', label: 'Discover', icon: Icons.explore_outlined),
];

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final unseen = ref.watch(unseenShelfCountProvider);
    final selected = _tabs.indexWhere((t) => t.path == location);

    return Scaffold(
      body: child,
      // The bar itself, and the rule it enforces, live in
      // widgets/common.dart so both are testable without a router.
      bottomNavigationBar: SillageTabBar(
        selectedIndex: selected < 0 ? 0 : selected,
        tabs: [
          for (final tab in _tabs)
            TabSpec(
              label: tab.label,
              icon: tab.icon,
              onTap: () => context.go(tab.path),
              // Only the shelf carries a count, and only while the user is
              // somewhere else — the Shelf screen clears it on arrival.
              badgeCount: tab.path == '/collection' ? unseen : 0,
            ),
        ],
      ),
    );
  }
}
