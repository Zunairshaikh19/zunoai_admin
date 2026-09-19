import 'package:flutter/material.dart';
import '../../users/presentation/user_management_screen.dart';
import '../../prompts/presentation/prompt_management_screen.dart';
import '../../support/presentation/admin_support_screen.dart';
import '../../marketing/presentation/marketing_screen.dart';
import '../../calculator/presentation/cost_calculator_screen.dart';

import '../presentation/stats_dashboard_screen.dart';
import '../../settings/presentation/admin_settings_screen.dart';

class AdminRootScreen extends StatefulWidget {
  const AdminRootScreen({super.key});

  @override
  State<AdminRootScreen> createState() => _AdminRootScreenState();
}

class _AdminRootScreenState extends State<AdminRootScreen> {
  int _selectedIndex = 0;

  final List<Widget> _screens = [
    const StatsDashboardScreen(),
    const UserManagementScreen(),
    const PromptManagementScreen(),
    const AdminSupportScreen(),
    const MarketingScreen(),
    const CostCalculatorScreen(),
    const AdminSettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) => setState(() => _selectedIndex = index),
            labelType: NavigationRailLabelType.all,
            backgroundColor: const Color(0xFF1E1E1E),
            selectedIconTheme: const IconThemeData(color: Colors.purpleAccent),
            unselectedIconTheme: const IconThemeData(color: Colors.white54),
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.dashboard), label: Text('Dashboard')),
              NavigationRailDestination(icon: Icon(Icons.people), label: Text('Users')),
              NavigationRailDestination(icon: Icon(Icons.art_track), label: Text('Prompts')),
              NavigationRailDestination(icon: Icon(Icons.support_agent), label: Text('Support')),
              NavigationRailDestination(icon: Icon(Icons.campaign), label: Text('Marketing')),
              NavigationRailDestination(icon: Icon(Icons.calculate), label: Text('Calculator')),
              NavigationRailDestination(icon: Icon(Icons.settings), label: Text('Settings')),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(child: _screens[_selectedIndex]),
        ],
      ),
    );
  }
}
