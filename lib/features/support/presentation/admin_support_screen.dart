import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../models/support_message.dart';
import '../../../models/user_model.dart';
import '../../users/presentation/user_management_screen.dart';

final ticketsStreamProvider = StreamProvider((ref) => ref.watch(firebaseServiceProvider).getSupportTickets());

final userStreamProvider = StreamProvider.family<UserModel?, String>((ref, uid) {
  return ref.watch(firebaseServiceProvider).getAllUsers().map((users) => 
    users.firstWhere((u) => u.uid == uid));
});

class AdminSupportScreen extends ConsumerStatefulWidget {
  const AdminSupportScreen({super.key});

  @override
  ConsumerState<AdminSupportScreen> createState() => _AdminSupportScreenState();
}

class _AdminSupportScreenState extends ConsumerState<AdminSupportScreen> {
  String? selectedTicketId;
  String? selectedUserId;

  @override
  Widget build(BuildContext context) {
    final ticketsAsync = ref.watch(ticketsStreamProvider);

    return Scaffold(
      appBar: AppBar(title: const Text("Customer Support Inbox")),
      body: Row(
        children: [
          // Sidebar: Ticket List
          SizedBox(
            width: 300,
            child: ticketsAsync.when(
              data: (tickets) => ListView.builder(
                itemCount: tickets.length,
                itemBuilder: (context, index) {
                  final ticket = tickets[index];
                  return Consumer(
                    builder: (context, ref, child) {
                      final userAsync = ref.watch(userStreamProvider(ticket['userId']));
                      return ListTile(
                        selected: selectedTicketId == ticket['id'],
                        title: userAsync.when(
                          data: (user) => Text(user?.email ?? ticket['userId'], style: const TextStyle(fontWeight: FontWeight.bold)),
                          loading: () => const Text("Loading...", style: TextStyle(color: Colors.white24)),
                          error: (_, __) => Text(ticket['userId']),
                        ),
                        subtitle: Text(ticket['lastMessage'] ?? 'No messages', maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => setState(() {
                          selectedTicketId = ticket['id'];
                          selectedUserId = ticket['userId'];
                        }),
                      );
                    },
                  );
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(child: Text("Error: $err")),
            ),
          ),
          const VerticalDivider(width: 1),
          // Main Area
          Expanded(
            child: selectedTicketId == null
                ? const Center(child: Text("Select a ticket to view conversation"))
                : Row(
                    children: [
                      Expanded(child: _ChatArea(ticketId: selectedTicketId!)),
                      const VerticalDivider(width: 1),
                      if (selectedUserId != null)
                        _UserActionPanel(uid: selectedUserId!),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _UserActionPanel extends ConsumerWidget {
  final String uid;
  const _UserActionPanel({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userStreamProvider(uid));

    return SizedBox(
      width: 250,
      child: userAsync.when(
        data: (user) {
          if (user == null) return const Center(child: Text("User not found"));
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Quick Actions", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                const SizedBox(height: 24),
                Text("Email: ${user.email}", style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                Text("Coins: ${user.coins}"),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => ref.read(firebaseServiceProvider).toggleUserBlock(user.uid, !user.isBlocked),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: user.isBlocked ? Colors.green : Colors.red,
                    minimumSize: const Size(double.infinity, 45),
                  ),
                  child: Text(user.isBlocked ? "Unblock User" : "Block User"),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: () => _showAddCoinsDialog(context, ref, user.uid),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(double.infinity, 45),
                  ),
                  child: const Text("Give 100 Coins"),
                ),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text("Error: $err")),
      ),
    );
  }

  void _showAddCoinsDialog(BuildContext context, WidgetRef ref, String uid) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Add Coins"),
        content: const Text("Are you sure you want to grant 100 coins to this user?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () {
              ref.read(firebaseServiceProvider).giveUserCoins(uid, 100);
              Navigator.pop(context);
            },
            child: const Text("Confirm"),
          ),
        ],
      ),
    );
  }
}

class _ChatArea extends ConsumerWidget {
  final String ticketId;
  const _ChatArea({required this.ticketId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messagesAsync = ref.watch(messagesStreamProvider(ticketId));
    final controller = TextEditingController();

    return Column(
      children: [
        Expanded(
          child: messagesAsync.when(
            data: (messages) => ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(16),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final msg = messages[index];
                final isMe = msg.isAdmin;
                return Align(
                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isMe ? Colors.purpleAccent : Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (msg.attachmentUrl != null)
                          Image.network(msg.attachmentUrl!, height: 200),
                        Text(msg.text),
                        Text(
                          DateFormat.jm().format(msg.timestamp),
                          style: const TextStyle(fontSize: 10, color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(child: Text("Error: $err")),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white10,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  decoration: const InputDecoration(hintText: "Type a reply..."),
                  onSubmitted: (val) {
                    if (val.trim().isNotEmpty) {
                      ref.read(firebaseServiceProvider).sendAdminMessage(ticketId, val.trim());
                      controller.clear();
                    }
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send, color: Colors.purpleAccent),
                onPressed: () {
                  if (controller.text.trim().isNotEmpty) {
                    ref.read(firebaseServiceProvider).sendAdminMessage(ticketId, controller.text.trim());
                    controller.clear();
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final messagesStreamProvider = StreamProvider.family<List<SupportMessage>, String>((ref, ticketId) {
  return ref.watch(firebaseServiceProvider).getMessages(ticketId);
});
