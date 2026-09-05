import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../presentation/admin_root_screen.dart';
import '../../users/presentation/user_management_screen.dart';
import '../../../models/user_model.dart';
import '../../prompts/presentation/prompt_management_screen.dart';

class StatsDashboardScreen extends ConsumerWidget {
  const StatsDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usersAsync = ref.watch(usersStreamProvider);
    final promptsAsync = ref.watch(promptsStreamProvider);

    return Scaffold(
      appBar: AppBar(title: const Text("Admin Dashboard")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Overview Statistics", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 32),
            Row(
              children: [
                usersAsync.when(
                  data: (users) {
                    final total = users.length;
                    final paid = users.where((u) => u.tier == UserTier.paid).length;
                    final free = total - paid;
                    final blocked = users.where((u) => u.isBlocked).length;

                    return Expanded(
                      child: Row(
                        children: [
                          _StatCard("Total Users", "$total", Icons.people, Colors.blue),
                          const SizedBox(width: 16),
                          _StatCard("Premium Users", "$paid", Icons.star, Colors.amber),
                          const SizedBox(width: 16),
                          _StatCard("Free Users", "$free", Icons.person_outline, Colors.grey),
                          const SizedBox(width: 16),
                          _StatCard("Blocked Users", "$blocked", Icons.block, Colors.red),
                        ],
                      ),
                    );
                  },
                  loading: () => const Expanded(child: Center(child: CircularProgressIndicator())),
                  error: (err, _) => Text("Error: $err"),
                ),
              ],
            ),
            const SizedBox(height: 32),
            promptsAsync.when(
              data: (prompts) => Row(
                children: [
                  _StatCard("Total Prompts", "${prompts.length}", Icons.art_track, Colors.purpleAccent),
                  const SizedBox(width: 16),
                  _StatCard("Premium Prompts", "${prompts.where((p) => p.isPremium).length}", Icons.auto_awesome, Colors.amberAccent),
                ],
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Text("Error: $err"),
            ),
            const SizedBox(height: 48),
            const Text("Recent Activity (Upcoming)", style: TextStyle(fontSize: 18, color: Colors.white38)),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String title, String value, IconData icon, Color color) {
    return _StatCard(title, value, icon, color);
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard(this.title, this.value, this.icon, this.color);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(height: 16),
              Text(value, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(title, style: const TextStyle(color: Colors.white54, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}
