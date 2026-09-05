import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AdminSettingsScreen extends ConsumerStatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  ConsumerState<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends ConsumerState<AdminSettingsScreen> {
  final _apiKeyController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final doc = await FirebaseFirestore.instance.collection('settings').doc('config').get();
    if (doc.exists) {
      setState(() => _apiKeyController.text = doc.data()?['nanoBananaApiKey'] ?? '');
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isLoading = true);
    await FirebaseFirestore.instance.collection('settings').doc('config').set({
      'nanoBananaApiKey': _apiKeyController.text.trim(),
    }, SetOptions(merge: true));
    setState(() => _isLoading = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Settings saved!")));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("System Settings")),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("API Configuration", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            SizedBox(
              width: 500,
              child: TextField(
                controller: _apiKeyController,
                decoration: const InputDecoration(
                  labelText: "Nano Banana / Gemini API Key",
                  border: OutlineInputBorder(),
                  helperText: "Used by the mobile app for AI generation",
                ),
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _isLoading ? null : _saveSettings,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purpleAccent,
                minimumSize: const Size(200, 50),
              ),
              child: _isLoading ? const CircularProgressIndicator() : const Text("Save Configuration"),
            ),
          ],
        ),
      ),
    );
  }
}
