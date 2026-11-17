import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'guide/guide_screen.dart';
import 'home/home_screen.dart';
import 'journal/journal_screen.dart';
import 'projects/projects_screen.dart';

/// Navigation principale : rail latéral sur grand écran (Linux), barre du bas
/// sur téléphone (Android).
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => AppShellState();
}

class AppShellState extends State<AppShell> {
  int _index = 0;

  void goTo(int index) => setState(() => _index = index);

  static const _destinations = [
    (Icons.science_outlined, Icons.science_rounded, 'Laboratoire'),
    (Icons.folder_outlined, Icons.folder_rounded, 'Projets'),
    (Icons.receipt_long_outlined, Icons.receipt_long_rounded, 'Journal'),
    (Icons.menu_book_outlined, Icons.menu_book_rounded, 'Mode d\'emploi'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final pages = [
      HomeScreen(onOpenProjects: () => goTo(1)),
      const ProjectsScreen(),
      const JournalScreen(),
      const GuideScreen(),
    ];
    final body = IndexedStack(index: _index, children: pages);

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: goTo,
              labelType: NavigationRailLabelType.all,
              leading: const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: _ThemeToggle()),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: goTo,
        destinations: [
          for (final d in _destinations) NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3),
        ],
      ),
    );
  }
}

class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) => const ThemeMenuButton();
}

/// Choix du thème : système, clair, sombre.
class ThemeMenuButton extends StatelessWidget {
  const ThemeMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final icon = switch (state.themeMode) {
      ThemeMode.light => Icons.light_mode_rounded,
      ThemeMode.dark => Icons.dark_mode_rounded,
      ThemeMode.system => Icons.brightness_auto_rounded,
    };
    return PopupMenuButton<ThemeMode>(
      tooltip: 'Thème',
      icon: Icon(icon),
      initialValue: state.themeMode,
      onSelected: state.setThemeMode,
      itemBuilder: (_) => const [
        PopupMenuItem(value: ThemeMode.system, child: Text('Thème du système')),
        PopupMenuItem(value: ThemeMode.light, child: Text('Thème clair')),
        PopupMenuItem(value: ThemeMode.dark, child: Text('Thème sombre')),
      ],
    );
  }
}
