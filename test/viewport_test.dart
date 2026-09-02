/// Layout tests across nine viewports.
///
/// =============================================================================
/// WHY NINE, AND WHY THIS IS NOT PARANOIA
/// =============================================================================
/// `calculus-lab-app` shipped a ~190px Column overflow that put the answer pad
/// out of reach, and two more surfaced behind the first fix. Overflow does not
/// throw in release builds — it draws a striped bar in debug and silently clips
/// in production — so the only way it gets caught is by pumping the real widget
/// at a real size.
///
/// Flutter raises overflow through `FlutterError.onError`, which `testWidgets`
/// turns into a failure automatically. Every test below therefore asserts
/// "no overflow at this size" simply by pumping successfully, and then asserts
/// the behaviour that is supposed to prevent it.
///
/// The sizes span a small phone in portrait through a desktop window, plus the
/// pathological narrow case that a resizable desktop window can actually reach.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillage/core/models.dart';
import 'package:sillage/theme/theme.dart';
import 'package:sillage/widgets/common.dart';

/// (label, logical size). Real devices, plus two deliberate extremes.
const viewports = <(String, Size)>[
  ('iPhone SE portrait', Size(320, 568)),
  ('small Android portrait', Size(360, 640)),
  ('iPhone 14 portrait', Size(390, 844)),
  ('large phone portrait', Size(430, 932)),
  ('phone landscape', Size(844, 390)),
  ('tablet portrait', Size(768, 1024)),
  ('tablet landscape', Size(1024, 768)),
  ('desktop window', Size(1440, 900)),
  // Narrower than any phone. A desktop window can be dragged to this, and it is
  // where a nav bar that scrolls instead of dividing gives itself away.
  ('pathologically narrow', Size(240, 600)),
];

Widget _host(Widget child, {bool reduceMotion = false}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: child),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, Size size, Widget widget) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
  await tester.pump();
}

NoteRef _note(String name, NoteTier tier, [int position = 0]) =>
    NoteRef(key: name.toLowerCase(), displayName: name, tier: tier, position: position);

/// A pyramid with long note names in every tier — the realistic worst case for
/// a wrapping chip layout.
final _bigPyramid = <NoteRef>[
  _note('Calabrian Bergamot', NoteTier.top, 0),
  _note('Sichuan Pepper', NoteTier.top, 1),
  _note('Pink Peppercorn', NoteTier.top, 2),
  _note('Elemi', NoteTier.top, 3),
  _note('Lavender Absolute', NoteTier.heart, 0),
  _note('Vetiver from Haiti', NoteTier.heart, 1),
  _note('Star Anise', NoteTier.heart, 2),
  _note('Ambroxan', NoteTier.base, 0),
  _note('Madagascan Vanilla', NoteTier.base, 1),
  _note('Patchouli', NoteTier.base, 2),
  _note('Cedar', NoteTier.base, 3),
];

void main() {
  // ===========================================================================
  group('the note pyramid survives every width', () {
    for (final (name, size) in viewports) {
      testWidgets('no overflow at $name', (tester) async {
        await _pumpAt(
          tester,
          size,
          _host(
            SingleChildScrollView(
              padding: const EdgeInsets.all(Space.lg),
              child: NotePyramid(notes: _bigPyramid),
            ),
          ),
        );
        // Reaching here without FlutterError firing IS the assertion.
        expect(find.byType(NotePyramid), findsOneWidget);
        expect(find.text('Calabrian Bergamot'), findsOneWidget);
      });
    }

    testWidgets('tiers are labelled and ordered top, heart, base', (tester) async {
      await _pumpAt(tester, const Size(390, 844),
          _host(NotePyramid(notes: _bigPyramid)));
      final top = tester.getTopLeft(find.text('TOP')).dy;
      final heart = tester.getTopLeft(find.text('HEART')).dy;
      final base = tester.getTopLeft(find.text('BASE')).dy;
      expect(top, lessThan(heart));
      expect(heart, lessThan(base));
    });

    testWidgets('an empty pyramid says so rather than rendering nothing',
        (tester) async {
      await _pumpAt(
          tester, const Size(390, 844), _host(const NotePyramid(notes: [])));
      expect(find.text('No notes recorded yet.'), findsOneWidget);
    });
  });

  // ===========================================================================
  group('the tab bar divides the width and never scrolls', () {
    List<TabSpec> tabs() => [
          for (final label in ['Shelf', 'Scan', 'Taste', 'Discover'])
            TabSpec(label: label, icon: Icons.circle, onTap: () {}),
        ];

    for (final (name, size) in viewports) {
      testWidgets('no overflow at $name', (tester) async {
        await _pumpAt(
          tester,
          size,
          _host(
            Align(
              alignment: Alignment.bottomCenter,
              child: SillageTabBar(tabs: tabs(), selectedIndex: 0),
            ),
          ),
        );
        expect(find.byType(SillageTabBar), findsOneWidget);
        // Four icons, always. The set is never a filmstrip.
        expect(find.byIcon(Icons.circle), findsNWidgets(4));
      });
    }

    testWidgets('every cell gets an equal share of the width', (tester) async {
      await _pumpAt(
        tester,
        const Size(400, 800),
        _host(Align(
          alignment: Alignment.bottomCenter,
          child: SillageTabBar(tabs: tabs(), selectedIndex: 0),
        )),
      );
      final cells = find.byType(InkWell);
      expect(cells, findsNWidgets(4));
      final first = tester.getSize(cells.at(0));
      for (var i = 1; i < 4; i++) {
        expect(tester.getSize(cells.at(i)).width, closeTo(first.width, 0.5));
      }
      // And they add up to the full width — nothing is off-screen.
      expect(first.width * 4, closeTo(400, 1.0));
    });

    testWidgets('labels are dropped before icons when space runs out',
        (tester) async {
      // 240 / 4 = 60px per cell, under the 76px the label needs.
      await _pumpAt(
        tester,
        const Size(240, 600),
        _host(Align(
          alignment: Alignment.bottomCenter,
          child: SillageTabBar(tabs: tabs(), selectedIndex: 0),
        )),
      );
      expect(find.text('Discover'), findsNothing);
      expect(find.byIcon(Icons.circle), findsNWidgets(4));
    });

    testWidgets('a dropped label survives as the accessible name',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpAt(
        tester,
        const Size(240, 600),
        _host(Align(
          alignment: Alignment.bottomCenter,
          child: SillageTabBar(tabs: tabs(), selectedIndex: 0),
        )),
      );
      // Not drawn, but still announced — dropping the label must not remove
      // the tab from a screen reader.
      expect(find.bySemanticsLabel('Discover'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a badge draws over the icon without resizing the cell',
        (tester) async {
      final plain = <TabSpec>[
        for (final l in ['Shelf', 'Scan', 'Taste', 'Discover'])
          TabSpec(label: l, icon: Icons.circle, onTap: () {}),
      ];
      await _pumpAt(tester, const Size(390, 844),
          _host(Align(alignment: Alignment.bottomCenter,
              child: SillageTabBar(tabs: plain, selectedIndex: 0))));
      final widthWithout = tester.getSize(find.byType(InkWell).first).width;

      final badged = <TabSpec>[
        TabSpec(label: 'Shelf', icon: Icons.circle, onTap: () {}, badgeCount: 3),
        for (final l in ['Scan', 'Taste', 'Discover'])
          TabSpec(label: l, icon: Icons.circle, onTap: () {}),
      ];
      await _pumpAt(tester, const Size(390, 844),
          _host(Align(alignment: Alignment.bottomCenter,
              child: SillageTabBar(tabs: badged, selectedIndex: 1))));

      expect(find.text('3'), findsOneWidget);
      // The count overlays the icon rather than displacing it, so a tab must
      // not change width or jump when a badge appears.
      expect(tester.getSize(find.byType(InkWell).first).width,
          closeTo(widthWithout, 0.5));
    });

    testWidgets('a zero count draws nothing at all', (tester) async {
      final tabs = <TabSpec>[
        TabSpec(label: 'Shelf', icon: Icons.circle, onTap: () {}, badgeCount: 0),
        for (final l in ['Scan', 'Taste', 'Discover'])
          TabSpec(label: l, icon: Icons.circle, onTap: () {}),
      ];
      await _pumpAt(tester, const Size(390, 844),
          _host(Align(alignment: Alignment.bottomCenter,
              child: SillageTabBar(tabs: tabs, selectedIndex: 0))));
      expect(find.text('0'), findsNothing);
    });

    testWidgets('a runaway count stays two digits plus a marker',
        (tester) async {
      final tabs = <TabSpec>[
        TabSpec(label: 'Shelf', icon: Icons.circle, onTap: () {}, badgeCount: 250),
        for (final l in ['Scan', 'Taste', 'Discover'])
          TabSpec(label: l, icon: Icons.circle, onTap: () {}),
      ];
      await _pumpAt(tester, const Size(320, 568),
          _host(Align(alignment: Alignment.bottomCenter,
              child: SillageTabBar(tabs: tabs, selectedIndex: 0))));
      expect(find.text('99+'), findsOneWidget);
      expect(find.text('250'), findsNothing);
    });

    testWidgets('the badge survives the narrowest viewport', (tester) async {
      // 240px is where labels are already dropped; the count must still fit.
      final tabs = <TabSpec>[
        TabSpec(label: 'Shelf', icon: Icons.circle, onTap: () {}, badgeCount: 12),
        for (final l in ['Scan', 'Taste', 'Discover'])
          TabSpec(label: l, icon: Icons.circle, onTap: () {}),
      ];
      await _pumpAt(tester, const Size(240, 600),
          _host(Align(alignment: Alignment.bottomCenter,
              child: SillageTabBar(tabs: tabs, selectedIndex: 0))));
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('labels are shown when there is room', (tester) async {
      await _pumpAt(
        tester,
        const Size(390, 844),
        _host(Align(
          alignment: Alignment.bottomCenter,
          child: SillageTabBar(tabs: tabs(), selectedIndex: 0),
        )),
      );
      expect(find.text('Discover'), findsOneWidget);
    });
  });

  // ===========================================================================
  group('busy state', () {
    testWidgets('animates by default', (tester) async {
      await _pumpAt(tester, const Size(390, 844), _host(const BusyBar()));
      expect(find.byType(BusyBar), findsOneWidget);
      // A moving element exists rather than a static rule. Scoped to the bar's
      // own subtree: MaterialApp keeps an AnimatedBuilder of its own for the
      // title, so an unscoped finder would pass no matter what BusyBar drew.
      expect(
        find.descendant(
          of: find.byType(BusyBar),
          matching: find.byType(AnimatedBuilder),
        ),
        findsOneWidget,
      );
      // Settle would never complete on a repeating animation.
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('falls back to something static under reduced motion',
        (tester) async {
      await _pumpAt(
        tester,
        const Size(390, 844),
        _host(const BusyBar(), reduceMotion: true),
      );
      // The fallback still reads as busy because it is drawn at all.
      expect(find.byType(BusyBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BusyBar),
          matching: find.byType(AnimatedBuilder),
        ),
        findsNothing,
      );
      // No pending timers, so the tree settles — which a repeating controller
      // would never allow.
      await tester.pumpAndSettle();
    });
  });

  // ===========================================================================
  group('provenance is visible, not buried', () {
    testWidgets('model-proposed notes are marked unverified', (tester) async {
      await _pumpAt(tester, const Size(390, 844),
          _host(const ProvenanceBadge(source: Provenance.model)));
      expect(find.text('UNVERIFIED'), findsOneWidget);
    });

    testWidgets('a human-confirmed pyramid reads differently', (tester) async {
      await _pumpAt(tester, const Size(390, 844),
          _host(const ProvenanceBadge(source: Provenance.user)));
      expect(find.text('CONFIRMED'), findsOneWidget);
    });
  });

  // ===========================================================================
  group('back control', () {
    testWidgets('is a bordered chip at tap height, not an arrow link',
        (tester) async {
      await _pumpAt(tester, const Size(390, 844), _host(const BackChip()));
      final size = tester.getSize(find.byType(BackChip));
      // DESIGN.md: a real tap target, not a 16px underlined run of text.
      expect(size.height, greaterThanOrEqualTo(44));
      expect(find.byIcon(Icons.chevron_left), findsOneWidget);
      // And no literal arrow glyph anywhere.
      expect(find.text('←'), findsNothing);
    });
  });

  // ===========================================================================
  group('room at the bottom', () {
    testWidgets('the gutter reserves bar height plus inset plus a margin',
        (tester) async {
      const barHeight = 60.0;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(bottom: 34)),
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: BottomGutter(barHeight: barHeight)),
          ),
        ),
      );
      final size = tester.getSize(find.byType(BottomGutter));
      // 60 bar + 34 home indicator + the gutter itself.
      expect(size.height, barHeight + 34 + Space.bottomBarGutter);
      expect(size.height, greaterThan(barHeight + 34));
    });
  });

  // ===========================================================================
  group('both themes are first-class', () {
    for (final brightness in Brightness.values) {
      testWidgets('the pyramid renders in ${brightness.name}', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(brightness),
            home: Scaffold(body: NotePyramid(notes: _bigPyramid)),
          ),
        );
        expect(find.byType(NotePyramid), findsOneWidget);
      });
    }

    test('every corner is square, per the house style', () {
      expect(squareRadius, BorderRadius.zero);
      for (final brightness in Brightness.values) {
        final theme = buildTheme(brightness);
        final shape = theme.cardTheme.shape;
        expect(shape, isA<RoundedRectangleBorder>());
        expect((shape! as RoundedRectangleBorder).borderRadius,
            BorderRadius.zero);
      }
    });

    test('the palette carries no chroma but the destructive token', () {
      // A seeded ColorScheme would introduce tonal chroma everywhere, which is
      // exactly what the house style rules out — so this asserts the greys stay
      // grey.
      //
      // The tolerance is NOT zero, and that is deliberate: zinc is a very
      // slightly cool grey (c500 is #71717A, blue 9/255 above red), which is
      // what distinguishes it from a flat neutral. DESIGN.md says "~0 chroma",
      // not zero. The bound below is loose enough to admit zinc's cast and far
      // too tight to admit an actual accent colour.
      const greyTolerance = 0.06;
      for (final tokens in [SillageTokens.light, SillageTokens.dark]) {
        for (final colour in [
          tokens.background,
          tokens.surface,
          tokens.foreground,
          tokens.mutedForeground,
          tokens.border,
          tokens.borderStrong,
        ]) {
          expect(colour.r, closeTo(colour.g, greyTolerance));
          expect(colour.g, closeTo(colour.b, greyTolerance));
        }
        // The one exception.
        expect(tokens.destructive.r, greaterThan(tokens.destructive.b + 0.2));
      }
    });
  });
}
