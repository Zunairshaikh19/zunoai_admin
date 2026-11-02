import 'dart:convert';
import 'dart:js_interop';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart' as fp;
import '../../../models/image_model_info.dart';
import '../../../services/firebase_service.dart';

// Defined in web/index.html — downloads text as a file in the browser.
@JS('zunoDownloadText')
external void _downloadText(JSString filename, JSString text);

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

  // Economy fields. The fallback values below are the SAME as DEFAULT_ECONOMY in
  // supabase/functions/_shared/lib.ts (and economy-defaults.json): they are what
  // the backend actually uses when a field is missing from Firestore, so what the
  // panel shows for a missing field is always the truth, and saving it changes nothing.
  static const _defSignupBonus = 40;
  static const _defReferralReward = 20;
  static const _defReferralCap = 10;
  static const _defGenerationCost = 40;
  static const _defAdReward = 10;
  static const _defDailyBonusFree = 5;
  static const _defDailyBonusPremium = 52;
  static const _defDailyBonusPremiumYearly = 33;
  static const _defFreeAdLimit = 3;
  static const _defPremiumAdLimit = 0;
  static const _defWatermarkRemovalCost = 20;
  static const _defMaxGenerationsPerDay = 60;
  static const _defShareUnlockReward = 15;
  static const _defStreakRewards = [2, 2, 3, 3, 4, 5, 10];

  final _signupBonusController = TextEditingController(text: "$_defSignupBonus");
  final _referralRewardController = TextEditingController(text: "$_defReferralReward");
  final _referralCapController = TextEditingController(text: "$_defReferralCap");
  final _generationCostController = TextEditingController(text: "$_defGenerationCost");
  final _adRewardController = TextEditingController(text: "$_defAdReward");
  final _dailyBonusFreeController = TextEditingController(text: "$_defDailyBonusFree");
  final _dailyBonusPremiumController = TextEditingController(text: "$_defDailyBonusPremium");
  final _dailyBonusPremiumYearlyController = TextEditingController(text: "$_defDailyBonusPremiumYearly");
  final _freeAdLimitController = TextEditingController(text: "$_defFreeAdLimit");
  final _premiumAdLimitController = TextEditingController(text: "$_defPremiumAdLimit");
  final _watermarkRemovalCostController = TextEditingController(text: "$_defWatermarkRemovalCost");
  final _maxGenerationsPerDayController = TextEditingController(text: "$_defMaxGenerationsPerDay");
  final _shareUnlockRewardController = TextEditingController(text: "$_defShareUnlockReward");
  final _streakRewardsController = TextEditingController(text: _defStreakRewards.join(', '));

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
        _signupBonusController.text = "${data['signupBonus'] ?? _defSignupBonus}";
        _referralRewardController.text = "${data['referralReward'] ?? _defReferralReward}";
        _referralCapController.text = "${data['referralCap'] ?? _defReferralCap}";
        _generationCostController.text = "${data['generationCost'] ?? _defGenerationCost}";
        _adRewardController.text = "${data['adRewardAmount'] ?? _defAdReward}";
        _dailyBonusFreeController.text = "${data['dailyBonusFree'] ?? _defDailyBonusFree}";
        _dailyBonusPremiumController.text = "${data['dailyBonusPremium'] ?? _defDailyBonusPremium}";
        _dailyBonusPremiumYearlyController.text =
            "${data['dailyBonusPremiumYearly'] ?? _defDailyBonusPremiumYearly}";
        _freeAdLimitController.text = "${data['freeAdLimitPerDay'] ?? _defFreeAdLimit}";
        _premiumAdLimitController.text = "${data['premiumAdLimitPerDay'] ?? _defPremiumAdLimit}";
        _watermarkRemovalCostController.text = "${data['watermarkRemovalCost'] ?? _defWatermarkRemovalCost}";
        _maxGenerationsPerDayController.text = "${data['maxGenerationsPerDay'] ?? _defMaxGenerationsPerDay}";
        _shareUnlockRewardController.text = "${data['shareUnlockReward'] ?? _defShareUnlockReward}";
        final streak = data['streakRewards'];
        _streakRewardsController.text =
            (streak is List && streak.isNotEmpty ? streak : _defStreakRewards).join(', ');
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

  /// Parses "2, 2, 3, 3, 4, 5, 10". Returns null if it isn't a clean list of
  /// positive whole numbers, so a typo can never wipe the streak table.
  List<int>? _parseStreakRewards(String text) {
    final parts = text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    final values = parts.map(int.tryParse).toList();
    if (values.any((v) => v == null || v <= 0)) return null;
    return values.cast<int>();
  }

  // --- Prompt secrets migration -------------------------------------------
  // The migration deletes the old public copy of every secret prompt, so the
  // button stays disabled until a backup has been downloaded in this session.
  bool _backupDownloaded = false;
  bool _isBackingUp = false;
  bool _isMigrating = false;

  Future<void> _downloadBackup() async {
    setState(() => _isBackingUp = true);
    try {
      final json = await FirebaseService().exportPromptsBackupJson();
      final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
      _downloadText('zunoai-prompts-backup-$stamp.json'.toJS, json.toJS);
      if (mounted) {
        setState(() => _backupDownloaded = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Backup download ho gaya. File ko safe jagah rakh lo.")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Backup fail hua: $e")));
      }
    } finally {
      if (mounted) setState(() => _isBackingUp = false);
    }
  }

  Future<void> _runMigration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Secret prompts ko tijori mein bhejun?"),
        content: const Text(
          "Har prompt ka secret text promptSecrets mein chala jayega aur purani public jagah "
          "(prompts) se HATA diya jayega. Yeh wapas nahi hota, is liye backup file sambhal kar rakho.\n\n"
          "Dobara chalane se koi nuqsan nahi hota.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text("Haan, migrate karo")),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isMigrating = true);
    try {
      final result = await FirebaseService().migratePromptSecrets();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ho gaya: ${result.migrated} prompts migrate hue, ${result.skipped} pehle se theek the.")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Migration fail hui: $e")));
      }
    } finally {
      if (mounted) setState(() => _isMigrating = false);
    }
  }

  // --- Template images: ImgBB -> R2 ---------------------------------------
  bool _isMovingImages = false;
  String _imageMoveStatus = '';

  Future<void> _runImageMigration() async {
    setState(() {
      _isMovingImages = true;
      _imageMoveStatus = 'Shuru ho raha hai...';
    });
    try {
      final r = await FirebaseService().migratePromptImages(
        onProgress: (m, s, f) {
          if (mounted) {
            setState(() => _imageMoveStatus = 'Chal raha hai... R2 par gayi: $m, pehle se theek: $s, fail: $f');
          }
        },
      );
      if (mounted) {
        final msg = 'Ho gaya: ${r.migrated} images R2 par gayi, ${r.skipped} pehle se theek thin, '
            '${r.failed} fail hui${r.failed > 0 ? " (Prompts page par Needs Cleanup filter mein dekho)" : ""}.';
        setState(() => _imageMoveStatus = msg);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _imageMoveStatus = '$e');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _isMovingImages = false);
    }
  }

  bool _isRepairing = false;
  String _repairStatus = '';

  Future<void> _runImageRepair() async {
    final picked = await fp.FilePicker.pickFile(
      type: fp.FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked == null) return;
    setState(() {
      _isRepairing = true;
      _repairStatus = 'JSON padh raha hai...';
    });
    try {
      final bytes = await picked.readAsBytes();
      final list = (jsonDecode(utf8.decode(bytes)) as List).cast<Map<String, dynamic>>();
      final r = await FirebaseService().repairImagesFromJson(
        list,
        onProgress: (fixed, ok, noMatch, failed, total) {
          if (mounted) {
            setState(() => _repairStatus =
                'Chal raha hai... theek kiyi: $fixed, pehle se R2 par: $ok, JSON mein match nahi: $noMatch, fail: $failed (total $total)');
          }
        },
      );
      if (mounted) {
        final msg = 'Ho gaya: ${r.fixed} theek hui, ${r.alreadyOk} pehle se R2 par thin, '
            '${r.noMatch} ka JSON mein match nahi mila, ${r.failed} fail hui.';
        setState(() => _repairStatus = msg);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _repairStatus = 'Error: $e');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isRepairing = false);
    }
  }

  Future<void> _saveEconomy() async {
    final streak = _parseStreakRewards(_streakRewardsController.text);
    if (streak == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Streak Rewards sahi nahi hai. Aise likho: 2, 2, 3, 3, 4, 5, 10 (kuch save nahi hua).")),
      );
      return;
    }

    setState(() => _isLoading = true);
    await FirebaseFirestore.instance.collection('settings').doc('economy').set({
      'signupBonus': int.tryParse(_signupBonusController.text) ?? _defSignupBonus,
      'referralReward': int.tryParse(_referralRewardController.text) ?? _defReferralReward,
      'referralCap': int.tryParse(_referralCapController.text) ?? _defReferralCap,
      'generationCost': int.tryParse(_generationCostController.text) ?? _defGenerationCost,
      'adRewardAmount': int.tryParse(_adRewardController.text) ?? _defAdReward,
      'dailyBonusFree': int.tryParse(_dailyBonusFreeController.text) ?? _defDailyBonusFree,
      'dailyBonusPremium': int.tryParse(_dailyBonusPremiumController.text) ?? _defDailyBonusPremium,
      'dailyBonusPremiumYearly':
          int.tryParse(_dailyBonusPremiumYearlyController.text) ?? _defDailyBonusPremiumYearly,
      'freeAdLimitPerDay': int.tryParse(_freeAdLimitController.text) ?? _defFreeAdLimit,
      'premiumAdLimitPerDay': int.tryParse(_premiumAdLimitController.text) ?? _defPremiumAdLimit,
      'watermarkRemovalCost': int.tryParse(_watermarkRemovalCostController.text) ?? _defWatermarkRemovalCost,
      'maxGenerationsPerDay': int.tryParse(_maxGenerationsPerDayController.text) ?? _defMaxGenerationsPerDay,
      'shareUnlockReward': int.tryParse(_shareUnlockRewardController.text) ?? _defShareUnlockReward,
      'streakRewards': streak,
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
                _numberField("Referral Cap", _referralCapController, "Max successful referrals that earn a reward per user"),
                _numberField("Generation Cost", _generationCostController, "Coins deducted per AI generation"),
                _numberField("Ad Reward", _adRewardController, "Coins earned per rewarded ad watched"),
                _numberField("Daily Bonus (Free)", _dailyBonusFreeController, "Coins granted on daily reset — free tier"),
                _numberField("Daily Bonus (Premium Monthly)", _dailyBonusPremiumController, "Coins granted on daily reset — monthly premium"),
                _numberField("Daily Bonus (Premium Yearly)", _dailyBonusPremiumYearlyController, "Coins granted on daily reset — yearly premium"),
                _numberField("Ad Limit (Free)", _freeAdLimitController, "Rewarded ads per day — free tier"),
                _numberField("Ad Limit (Premium)", _premiumAdLimitController, "Rewarded ads per day — premium tier"),
                _numberField("Watermark Removal", _watermarkRemovalCostController, "Coins to remove the watermark on one result"),
                _numberField("Max Generations / Day", _maxGenerationsPerDayController, "Hard daily cap on generations per user (abuse guard)"),
                _numberField("Share Reward", _shareUnlockRewardController, "Coins earned the first time a result is shared per generation"),
                _textField("Streak Rewards", _streakRewardsController, "Coins for login streak day 1..7, comma separated"),
              ],
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isLoading ? null : _saveEconomy,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent, minimumSize: const Size(200, 50)),
              child: _isLoading ? const CircularProgressIndicator() : const Text("Save Economy Settings"),
            ),

            const SizedBox(height: 48),
            const Text("Prompt Security", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Text(
              "Secret prompt text ko public prompts se hata kar promptSecrets (sirf admin/server) mein bhejna. "
              "Pehle backup lo, phir migrate karo. Naye prompts apne aap promptSecrets mein jate hain.",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _isBackingUp ? null : _downloadBackup,
                  icon: _isBackingUp
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download),
                  label: const Text("1. Download prompts backup"),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(260, 50)),
                ),
                ElevatedButton.icon(
                  onPressed: (_backupDownloaded && !_isMigrating) ? _runMigration : null,
                  icon: _isMigrating
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.lock),
                  label: Text(_backupDownloaded ? "2. Migrate prompts" : "2. Migrate prompts (pehle backup lo)"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent, minimumSize: const Size(260, 50)),
                ),
              ],
            ),

            const SizedBox(height: 48),
            const Text("Image Storage (R2)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Text(
              "Template images ko ImgBB se hata kar apni R2 storage par le jana. Ek hi baar chalao: har prompt ka "
              "ek read lagta hai aur jo image move hoti hai uska ek write. Dobara chalane par jo ho chuki woh skip hoti hain.",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isMovingImages ? null : _runImageMigration,
              icon: _isMovingImages
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload),
              label: const Text("Move template images to R2"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent, minimumSize: const Size(260, 50)),
            ),
            if (_imageMoveStatus.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_imageMoveStatus, style: const TextStyle(color: Colors.white70)),
            ],
            const SizedBox(height: 24),
            const Text(
              "Jo images ImgBB se move nahi hui (dead links), unhe original JSON se theek karo. "
              "Apni all_prompts_database.json chuno: har prompt ka secret text JSON se match hota hai "
              "aur uski original image R2 par copy hoti hai. Reads: prompts + secrets ek baar.",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _isRepairing ? null : _runImageRepair,
              icon: _isRepairing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.build),
              label: const Text("Fix images from JSON"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, minimumSize: const Size(260, 50)),
            ),
            if (_repairStatus.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_repairStatus, style: const TextStyle(color: Colors.white70)),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _textField(String label, TextEditingController controller, String helperText) {
    return SizedBox(
      width: 260,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
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
