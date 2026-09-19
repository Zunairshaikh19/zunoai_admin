import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../models/user_model.dart';
import '../../../services/firebase_service.dart';

final firebaseServiceProvider = Provider((ref) => FirebaseService());
final usersStreamProvider = StreamProvider((ref) => ref.watch(firebaseServiceProvider).getAllUsers());

class UserManagementScreen extends ConsumerWidget {
  const UserManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usersAsync = ref.watch(usersStreamProvider);

    return Scaffold(
      appBar: AppBar(title: const Text("User Management")),
      body: usersAsync.when(
        data: (users) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text("Email")),
              DataColumn(label: Text("Tier")),
              DataColumn(label: Text("Premium Until")),
              DataColumn(label: Text("Coins")),
              DataColumn(label: Text("Referrals")),
              DataColumn(label: Text("Activity")),
              DataColumn(label: Text("Push")),
              DataColumn(label: Text("Status")),
              DataColumn(label: Text("Actions")),
            ],
            rows: users.map((user) => DataRow(
              cells: [
                DataCell(Text(user.email)),
                DataCell(Chip(
                  label: Text(user.tier.name.toUpperCase()),
                  backgroundColor: user.tier == UserTier.paid ? Colors.amber.withOpacity(0.2) : Colors.white12,
                )),
                DataCell(Text(user.premiumExpiresAt != null
                    ? DateFormat.yMMMd().format(user.premiumExpiresAt!)
                    : "—")),
                DataCell(Text("${user.coins}")),
                DataCell(Text("${user.referralCount}")),
                DataCell(Text(user.lastActivity != null ? DateFormat.yMMMd().add_jm().format(user.lastActivity!) : "N/A")),
                DataCell(Icon(
                  user.fcmToken != null ? Icons.notifications_active : Icons.notifications_off,
                  color: user.fcmToken != null ? Colors.green : Colors.grey,
                  size: 18,
                )),
                DataCell(Text(user.isBlocked ? "Blocked" : "Active", style: TextStyle(color: user.isBlocked ? Colors.red : Colors.green))),
                DataCell(Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton(
                      onPressed: () => ref.read(firebaseServiceProvider).toggleUserBlock(user.uid, !user.isBlocked),
                      style: ElevatedButton.styleFrom(backgroundColor: user.isBlocked ? Colors.green : Colors.red),
                      child: Text(user.isBlocked ? "Unblock" : "Block"),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => showSetPremiumDialog(context, ref, user),
                      child: Text(user.tier == UserTier.paid ? "Edit Premium" : "Grant Premium"),
                    ),
                  ],
                )),
              ],
            )).toList(),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text("Error: $err")),
      ),
    );
  }
}

void showSetPremiumDialog(BuildContext context, WidgetRef ref, UserModel user) {
  final daysController = TextEditingController(text: "30");
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text("Premium — ${user.email}"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Use this to fix a customer whose purchase didn't activate correctly."),
          const SizedBox(height: 16),
          TextField(
            controller: daysController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: "Grant premium for how many days"),
          ),
        ],
      ),
      actions: [
        if (user.tier == UserTier.paid)
          TextButton(
            onPressed: () {
              ref.read(firebaseServiceProvider).setPremiumTier(user.uid);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text("Revoke Premium"),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        ElevatedButton(
          onPressed: () {
            final days = int.tryParse(daysController.text) ?? 30;
            ref.read(firebaseServiceProvider).setPremiumTier(user.uid, days: days);
            Navigator.pop(context);
          },
          child: const Text("Grant"),
        ),
      ],
    ),
  );
}
