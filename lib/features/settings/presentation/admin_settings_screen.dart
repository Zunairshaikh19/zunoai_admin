import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/image_model_info.dart';

class AdminSettingsScreen extends ConsumerStatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  ConsumerState<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends ConsumerState<AdminSettingsScreen> {
  final _apiKeyController = TextEditingController();
  bool _isLoading = false;
  bool _obscureKey = true;

  List<ImageModelInfo> _availableModels = [];
  bool _isLoadingModels = false;
  String? _modelsError;
  String? _selectedModel;

  // Economy fields — mirrors lib/models/economy_config.dart defaults on the mobile app,
  // so leaving these blank/unsaved keeps the app's current behavior unchanged.
  final _signupBonusController = TextEditingController(text: "40");
  final _referralRewardController = TextEditingController(text: "40");
  final _generationCostController = TextEditingController(text: "40");
  final _adRewardController = TextEditingController(text: "40");
  final _dailyBonusFreeController = TextEditingController(text: "40");
  final _dailyBonusPremiumController = TextEditingController(text: "80");
  final _freeAdLimitController = TextEditingController(text: "3");
  final _premiumAdLimitController = TextEditingController(text: "6");
  final _watermarkRemovalCostController = TextEditingController(text: "20");
  final _shareUnlockRewardController = TextEditingController(text: "15");

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _fetchAvailableModels();
  }

  Future<void> _loadSettings() async {
    final configDoc = await FirebaseFirestore.instance.collection('settings').doc('config').get();
    if (configDoc.exists) {
      final data = configDoc.data()!;
      setState(() {
        _apiKeyController.text = data['openRouterApiKey'] ?? '';
        _selectedModel = data['generationModel'];
      });
    }

    final economyDoc = await FirebaseFirestore.instance.collection('settings').doc('economy').get();
    if (economyDoc.exists) {
      final data = economyDoc.data()!;
      setState(() {
        _signupBonusController.text = "${data['signupBonus'] ?? 40}";
        _referralRewardController.text = "${data['referralReward'] ?? 40}";
        _generationCostController.text = "${data['generationCost'] ?? 40}";
        _adRewardController.text = "${data['adRewardAmount'] ?? 40}";
        _dailyBonusFreeController.text = "${data['dailyBonusFree'] ?? 40}";
        _dailyBonusPremiumController.text = "${data['dailyBonusPremium'] ?? 80}";
        _freeAdLimitController.text = "${data['freeAdLimitPerDay'] ?? 3}";
        _premiumAdLimitController.text = "${data['premiumAdLimitPerDay'] ?? 6}";
        _watermarkRemovalCostController.text = "${data['watermarkRemovalCost'] ?? 20}";
        _shareUnlockRewardController.text = "${data['shareUnlockReward'] ?? 15}";
      });
    }
  }

  // Fetches the live list of image-capable models directly from OpenRouter's
  // public catalog — no code change/redeploy needed when new models show up
  // or old ones are retired, unlike a hardcoded dropdown.
  Future<void> _fetchAvailableModels() async {
    setState(() {
      _isLoadingModels = true;
      _modelsError = null;
    });
    try {
      final models = await fetchImageModels();
      setState(() {
        _availableModels = models;
        _isLoadingModels = false;
        // Keep whatever was already saved even if it's momentarily missing
        // from the fetched list (e.g. a transient API hiccup).
        if (_selectedModel == null && models.isNotEmpty) {
          _selectedModel = models.first.id;
        }
      });
    } catch (e) {
      setState(() {
        _isLoadingModels = false;
        _modelsError = "Couldn't load model list: $e";
      });
    }
  }

  Future<void> _saveApiKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Save API configuration?"),
        content: const Text(
          "This replaces the key/model the live app uses for every image generation. "
          "Make sure it's correct — a bad key or unavailable model will break generation for all users.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text("Save")),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isLoading = true);
    await FirebaseFirestore.instance.collection('settings').doc('config').set({
      'openRouterApiKey': _apiKeyController.text.trim(),
      if (_selectedModel != null) 'generationModel': _selectedModel,
    }, SetOptions(merge: true));
    setState(() => _isLoading = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("API configuration saved!")));
    }
  }

  Future<void> _saveEconomy() async {
    setState(() => _isLoading = true);
    await FirebaseFirestore.instance.collection('settings').doc('economy').set({
      'signupBonus': int.tryParse(_signupBonusController.text) ?? 40,
      'referralReward': int.tryParse(_referralRewardController.text) ?? 40,
      'generationCost': int.tryParse(_generationCostController.text) ?? 40,
      'adRewardAmount': int.tryParse(_adRewardController.text) ?? 40,
      'dailyBonusFree': int.tryParse(_dailyBonusFreeController.text) ?? 40,
      'dailyBonusPremium': int.tryParse(_dailyBonusPremiumController.text) ?? 80,
      'freeAdLimitPerDay': int.tryParse(_freeAdLimitController.text) ?? 3,
      'premiumAdLimitPerDay': int.tryParse(_premiumAdLimitController.text) ?? 6,
      'watermarkRemovalCost': int.tryParse(_watermarkRemovalCostController.text) ?? 20,
      'shareUnlockReward': int.tryParse(_shareUnlockRewardController.text) ?? 15,
    }, SetOptions(merge: true));
    setState(() => _isLoading = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Economy settings saved — the app picks these up live, no release needed.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("System Settings")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("AI Generation (OpenRouter)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Text(
              "One key gives access to every image model below — switch models any time without a code release.",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 500,
              child: TextField(
                controller: _apiKeyController,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  labelText: "OpenRouter API Key",
                  border: const OutlineInputBorder(),
                  helperText: "From openrouter.ai — used by the mobile app's AI generation backend",
                  suffixIcon: IconButton(
                    icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 500,
              child: Row(
                children: [
                  Expanded(
                    child: _isLoadingModels
                        ? const LinearProgressIndicator()
                        : DropdownButtonFormField<String>(
                            initialValue: _availableModels.any((m) => m.id == _selectedModel) ? _selectedModel : null,
                            isExpanded: true,
                            itemHeight: null,
                            selectedItemBuilder: (context) => modelSelectedItemBuilder(_availableModels),
                            decoration: const InputDecoration(
                              labelText: "Image Generation Model",
                              border: OutlineInputBorder(),
                            ),
                            items: _availableModels.map((m) => modelDropdownItem(m)).toList(),
                            onChanged: (value) => setState(() => _selectedModel = value),
                          ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: "Refresh model list from OpenRouter",
                    onPressed: _isLoadingModels ? null : _fetchAvailableModels,
                  ),
                ],
              ),
            ),
            if (_modelsError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_modelsError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _saveApiKey,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent, minimumSize: const Size(200, 50)),
              child: const Text("Save API Configuration"),
            ),

            const SizedBox(height: 48),
            const Text("Coin Economy", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Text(
              "Changes apply immediately to the live app — no store release needed.",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 24,
              runSpacing: 16,
              children: [
                _numberField("Signup Bonus", _signupBonusController, "Coins a brand-new user starts with"),
                _numberField("Referral Reward", _referralRewardController, "Coins each side gets on a successful referral"),
                _numberField("Generation Cost", _generationCostController, "Coins deducted per AI generation"),
                _numberField("Ad Reward", _adRewardController, "Coins earned per rewarded ad watched"),
                _numberField("Daily Bonus (Free)", _dailyBonusFreeController, "Coins granted on daily reset — free tier"),
                _numberField("Daily Bonus (Premium)", _dailyBonusPremiumController, "Coins granted on daily reset — premium tier"),
                _numberField("Ad Limit (Free)", _freeAdLimitController, "Rewarded ads per day — free tier"),
                _numberField("Ad Limit (Premium)", _premiumAdLimitController, "Rewarded ads per day — premium tier"),
                _numberField("Watermark Removal", _watermarkRemovalCostController, "Coins to remove the watermark on one result"),
                _numberField("Share Reward", _shareUnlockRewardController, "Coins earned the first time a result is shared per generation"),
              ],
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLoading ? null : _saveEconomy,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent, minimumSize: const Size(200, 50)),
              child: _isLoading ? const CircularProgressIndicator() : const Text("Save Economy Settings"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _numberField(String label, TextEditingController controller, String helperText) {
    return SizedBox(
      width: 260,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
