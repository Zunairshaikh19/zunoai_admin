import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../users/presentation/user_management_screen.dart';

class MarketingScreen extends ConsumerStatefulWidget {
  const MarketingScreen({super.key});

  @override
  ConsumerState<MarketingScreen> createState() => _MarketingScreenState();
}

class _MarketingScreenState extends ConsumerState<MarketingScreen> {
  final _titleController = TextEditingController();
  final _messageController = TextEditingController();
  final _coinController = TextEditingController();
  
  String _targetType = 'Global'; // Global, Multiple, Single
  List<String> _selectedUserIds = [];
  bool _isSending = false;

  @override
  Widget build(BuildContext context) {
    final usersAsync = ref.watch(usersStreamProvider);

    return Scaffold(
      appBar: AppBar(title: const Text("Marketing & Promotions")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Compose Announcement / Voucher", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 32),
            
            // Notification Details
            SizedBox(
              width: 600,
              child: Column(
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: "Notification Title", border: OutlineInputBorder(), hintText: "e.g. Special Offer!"),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _messageController,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: "Message Body", border: OutlineInputBorder(), hintText: "Enter your marketing message here..."),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _coinController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "Voucher Coins (Optional)",
                      border: OutlineInputBorder(),
                      helperText: "Leave 0 or empty for no reward",
                      prefixIcon: Icon(Icons.generating_tokens, color: Colors.amber),
                    ),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 40),
            const Text("Select Target Audience", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            
            // Target Selection
            Row(
              children: [
                _buildTargetOption('Global', 'All Users'),
                const SizedBox(width: 16),
                _buildTargetOption('Multiple', 'Selected Users'),
                const SizedBox(width: 16),
                _buildTargetOption('Single', 'Specific User'),
              ],
            ),
            
            const SizedBox(height: 32),
            
            if (_targetType != 'Global')
              Container(
                height: 300,
                width: 600,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: usersAsync.when(
                  data: (users) => ListView.builder(
                    itemCount: users.length,
                    itemBuilder: (context, index) {
                      final user = users[index];
                      final isSelected = _selectedUserIds.contains(user.uid);
                      return CheckboxListTile(
                        title: Text(user.email),
                        subtitle: Text(user.displayName ?? 'No Name'),
                        value: isSelected,
                        onChanged: (val) {
                          setState(() {
                            if (val == true) {
                              if (_targetType == 'Single') _selectedUserIds = [user.uid];
                              else _selectedUserIds.add(user.uid);
                            } else {
                              _selectedUserIds.remove(user.uid);
                            }
                          });
                        },
                      );
                    },
                  ),
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Text("Error: $e"),
                ),
              ),
            
            const SizedBox(height: 48),
            
            ElevatedButton.icon(
              onPressed: _isSending ? null : _sendMarketing,
              icon: _isSending ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
              label: const Text("Dispatch Notification"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purpleAccent,
                minimumSize: const Size(250, 56),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTargetOption(String value, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _targetType == value,
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _targetType = value;
            _selectedUserIds = [];
          });
        }
      },
    );
  }

  Future<void> _sendMarketing() async {
    final title = _titleController.text.trim();
    final message = _messageController.text.trim();
    final coins = int.tryParse(_coinController.text) ?? 0;

    if (title.isEmpty || message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Title and Message are required")));
      return;
    }

    if (_targetType != 'Global' && _selectedUserIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please select at least one user")));
      return;
    }

    final audience = _targetType == 'Global'
        ? "ALL users"
        : _targetType == 'Single'
            ? "1 user"
            : "${_selectedUserIds.length} selected users";

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Send this notification?"),
        content: Text(
          "This will send \"$title\" to $audience"
          "${coins > 0 ? ' and grant $coins coins to each' : ''}. This can't be undone.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text("Send")),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isSending = true);

    try {
      final service = ref.read(firebaseServiceProvider);
      
      if (_targetType == 'Global') {
        await service.sendGlobalNotification(title: title, message: message, coinReward: coins > 0 ? coins : null);
      } else if (_targetType == 'Single') {
        await service.sendNotificationToUser(uid: _selectedUserIds.first, title: title, message: message, coinReward: coins > 0 ? coins : null);
      } else {
        await service.sendMassNotification(uids: _selectedUserIds, title: title, message: message, coinReward: coins > 0 ? coins : null);
      }

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Marketing campaign dispatched successfully!")));
      _titleController.clear();
      _messageController.clear();
      _coinController.clear();
      setState(() => _selectedUserIds = []);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    } finally {
      setState(() => _isSending = false);
    }
  }
}
