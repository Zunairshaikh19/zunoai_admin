import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/image_model_info.dart';
import '../../users/presentation/user_management_screen.dart';

class CostCalculatorScreen extends ConsumerStatefulWidget {
  const CostCalculatorScreen({super.key});

  @override
  ConsumerState<CostCalculatorScreen> createState() => _CostCalculatorScreenState();
}

class _CostCalculatorScreenState extends ConsumerState<CostCalculatorScreen> {
  List<ImageModelInfo> _models = [];
  bool _isLoadingModels = false;
  String? _modelsError;
  String? _selectedModelId;
  bool _useCompactNumbers = false;

  final _costPerImageController = TextEditingController(text: "0.04");
  final _coinsPerGenController = TextEditingController(text: "40");
  final _customUserCountController = TextEditingController(text: "1000");
  final _genPerUserController = TextEditingController(text: "5");

  // Subscription revenue is entered as "package price × what % of users pay
  // it" instead of a raw ARPU guess — easier to reason about than a dollar
  // figure with no visible math behind it.
  final _subscriptionPriceController = TextEditingController(text: "4.99");
  final _conversionPercentController = TextEditingController(text: "10");

  // Ad revenue is taxed/cut differently: Play Store takes a cut of
  // subscription/IAP revenue, but never touches ad revenue (AdMob pays that
  // out directly, already net of Google's own share).
  final _adArpuController = TextEditingController(text: "0.20");
  final _storeFeeController = TextEditingController(text: "15");

  // Editable since exchange rates move — not pinned to a live feed so the
  // calculator still works offline; update it yourself every so often.
  final _usdToPkrController = TextEditingController(text: "278");

  static const _conversionPresets = [
    ("Conservative", 2.0),
    ("Average", 5.0),
    ("Good", 10.0),
  ];

  @override
  void initState() {
    super.initState();
    _fetchModels();
    _loadGenerationCost();
  }

  Future<void> _loadGenerationCost() async {
    final doc = await FirebaseFirestore.instance.collection('settings').doc('economy').get();
    if (doc.exists && mounted) {
      setState(() => _coinsPerGenController.text = "${doc.data()?['generationCost'] ?? 40}");
    }
  }

  Future<void> _fetchModels() async {
    setState(() {
      _isLoadingModels = true;
      _modelsError = null;
    });
    try {
      final models = await fetchImageModels();
      setState(() {
        _models = models;
        _isLoadingModels = false;
        if (_selectedModelId == null && models.isNotEmpty) {
          _applyModel(models.first);
        }
      });
    } catch (e) {
      setState(() {
        _isLoadingModels = false;
        _modelsError = "Couldn't load model list: $e";
      });
    }
  }

  void _applyModel(ImageModelInfo model) {
    setState(() {
      _selectedModelId = model.id;
      if (model.estimatedCostPerImage != null) {
        _costPerImageController.text = model.estimatedCostPerImage!.toStringAsFixed(4);
      }
    });
  }

  double _num(TextEditingController c) => double.tryParse(c.text) ?? 0;

  Widget _buildScenario(String title, int userCount) {
    final costPerImage = _num(_costPerImageController);
    final genPerUser = _num(_genPerUserController);
    final subscriptionPrice = _num(_subscriptionPriceController);
    final conversionPct = _num(_conversionPercentController);
    final adArpu = _num(_adArpuController);
    final storeFeePct = _num(_storeFeeController);

    final totalGenerations = userCount * genPerUser;
    final totalCost = totalGenerations * costPerImage;

    final payingUsers = userCount * (conversionPct / 100);
    final grossIapRevenue = payingUsers * subscriptionPrice;
    final storeFeeAmount = grossIapRevenue * (storeFeePct / 100);
    final netIapRevenue = grossIapRevenue - storeFeeAmount;
    final adRevenue = userCount * adArpu; // AdMob payout is already net — no further cut

    final totalRevenue = netIapRevenue + adRevenue;
    final totalProfit = totalRevenue - totalCost;
    final profitPerUser = userCount > 0 ? totalProfit / userCount : 0;

    final usdToPkr = _num(_usdToPkrController);
    final yearlyProfit = totalProfit * 12;
    final yearlyProfitPerUser = profitPerUser * 12;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text("$userCount users · ${genPerUser.toStringAsFixed(0)} generations/user/month",
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 16),
            _statRow("Total generations / month", totalGenerations.toStringAsFixed(0)),
            _statRow("Total AI cost / month", "\$${totalCost.toStringAsFixed(2)}"),
            const Divider(),
            _statRow("Paying users (${conversionPct.toStringAsFixed(0)}%)", payingUsers.toStringAsFixed(0)),
            _statRow("Gross subscription/IAP revenue", "\$${grossIapRevenue.toStringAsFixed(2)}"),
            _statRow("− Store fee/tax (${storeFeePct.toStringAsFixed(0)}%)", "-\$${storeFeeAmount.toStringAsFixed(2)}",
                color: Colors.redAccent),
            _statRow("Net subscription/IAP revenue", "\$${netIapRevenue.toStringAsFixed(2)}"),
            _statRow("+ Ad revenue (net)", "\$${adRevenue.toStringAsFixed(2)}"),
            _statRow("= Total net revenue / month", "\$${totalRevenue.toStringAsFixed(2)}", bold: true),
            const Divider(),
            _statRow(
              "Net profit / month",
              "${_usd(totalProfit)}  (${_pkr(totalProfit, usdToPkr)})",
              color: totalProfit >= 0 ? Colors.green : Colors.redAccent,
              bold: true,
            ),
            _statRow("Profit per user / month", "${_usd(profitPerUser, decimals: 3)}  (${_pkr(profitPerUser, usdToPkr, decimals: 2)})"),
            const Divider(),
            _statRow(
              "Net profit / year",
              "${_usd(yearlyProfit)}  (${_pkr(yearlyProfit, usdToPkr)})",
              color: yearlyProfit >= 0 ? Colors.green : Colors.redAccent,
              bold: true,
            ),
            _statRow("Profit per user / year",
                "${_usd(yearlyProfitPerUser, decimals: 3)}  (${_pkr(yearlyProfitPerUser, usdToPkr, decimals: 2)})"),
          ],
        ),
      ),
    );
  }

  String _usd(num value, {int decimals = 2}) =>
      "\$${_useCompactNumbers ? _compact(value) : value.toStringAsFixed(decimals)}";

  String _pkr(num usdValue, double rate, {int decimals = 0}) {
    final pkr = usdValue * rate;
    return "Rs ${_useCompactNumbers ? _compact(pkr) : pkr.toStringAsFixed(decimals)}";
  }

  // K/M/B/T abbreviation — e.g. 1000000 -> "1M", -1250000000 -> "-1.25B".
  // Values under 1000 are shown in full since abbreviating them adds nothing.
  String _compact(num value) {
    final isNegative = value < 0;
    final absValue = value.abs();
    late final double scaled;
    late final String suffix;
    if (absValue >= 1e12) {
      scaled = absValue / 1e12;
      suffix = 'T';
    } else if (absValue >= 1e9) {
      scaled = absValue / 1e9;
      suffix = 'B';
    } else if (absValue >= 1e6) {
      scaled = absValue / 1e6;
      suffix = 'M';
    } else if (absValue >= 1e3) {
      scaled = absValue / 1e3;
      suffix = 'K';
    } else {
      return "${isNegative ? '-' : ''}${absValue.toStringAsFixed(2)}";
    }
    return "${isNegative ? '-' : ''}${scaled.toStringAsFixed(2)}$suffix";
  }

  Widget _statRow(String label, String value, {Color? color, bool bold = false}) {
    // Stacked (label above value) rather than side-by-side — large numbers
    // with both USD and PKR shown together can get long enough to overflow
    // a Row in the fixed-width scenario cards, especially once compact
    // formatting is off.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 2),
          Text(
            value,
            softWrap: true,
            style: TextStyle(
              color: color ?? Colors.white,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              fontSize: bold ? 16 : 14,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final usersAsync = ref.watch(usersStreamProvider);
    final realUserCount = usersAsync.valueOrNull?.length ?? 0;
    final customUserCount = int.tryParse(_customUserCountController.text) ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text("Cost Calculator")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Model & Cost", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 24,
              runSpacing: 16,
              children: [
                SizedBox(
                  width: 400,
                  child: _isLoadingModels
                      ? const LinearProgressIndicator()
                      : DropdownButtonFormField<String>(
                          initialValue: _models.any((m) => m.id == _selectedModelId) ? _selectedModelId : null,
                          isExpanded: true,
                          itemHeight: null,
                          selectedItemBuilder: (context) => modelSelectedItemBuilder(_models),
                          decoration: const InputDecoration(labelText: "Model", border: OutlineInputBorder()),
                          items: _models.map((m) => modelDropdownItem(m)).toList(),
                          onChanged: (value) {
                            final model = _models.firstWhere((m) => m.id == value);
                            _applyModel(model);
                          },
                        ),
                ),
                _field("Cost per image (\$)", _costPerImageController, "Editable — estimate, verify against real usage"),
                _field("Coins charged per generation", _coinsPerGenController, "From Coin Economy settings"),
              ],
            ),
            if (_modelsError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_modelsError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ),
            const SizedBox(height: 40),
            const Text("Assumptions", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Text(
              "Fill these in with your own estimates — everything below recalculates live.",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 24,
              runSpacing: 16,
              children: [
                _field("Hypothetical user count", _customUserCountController, "Try any number of users"),
                _field("Avg generations per user", _genPerUserController, "Per month, per user"),
                _field("Package price (\$/month)", _subscriptionPriceController, "Your Zuno AI Premium price"),
                _field("Conversion rate (%)", _conversionPercentController,
                    "% of total users who actually buy the package"),
                _field("Ad revenue ARPU (\$/month)", _adArpuController,
                    "Avg AdMob revenue per user — already net, no store fee applies"),
                _field("Store fee / tax (%)", _storeFeeController,
                    "Google Play cut on subscriptions/IAP — 15% (small biz) or 30% standard"),
                _field("USD → PKR rate", _usdToPkrController,
                    "Update occasionally — not live-fetched"),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text("Conversion rate presets:", style: TextStyle(color: Colors.white38, fontSize: 12)),
                for (final preset in _conversionPresets)
                  OutlinedButton(
                    onPressed: () => setState(() => _conversionPercentController.text = preset.$2.toStringAsFixed(0)),
                    child: Text("${preset.$1} (${preset.$2.toStringAsFixed(0)}%)"),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => setState(() {}),
              icon: const Icon(Icons.calculate),
              label: const Text("Recalculate"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent, minimumSize: const Size(200, 50)),
            ),
            const SizedBox(height: 40),
            Row(
              children: [
                const Text("Results", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(width: 16),
                Switch(
                  value: _useCompactNumbers,
                  onChanged: (v) => setState(() => _useCompactNumbers = v),
                ),
                const Text("Compact numbers (1M / 1B / 1T)", style: TextStyle(color: Colors.white70, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 24,
              runSpacing: 24,
              children: [
                SizedBox(width: 380, child: _buildScenario("Hypothetical Scenario", customUserCount)),
                SizedBox(
                  width: 380,
                  child: usersAsync.when(
                    data: (_) => _buildScenario("Actual Signed-Up Users (live)", realUserCount),
                    loading: () => const Card(
                      child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()),
                    ),
                    error: (e, _) => Card(child: Padding(padding: const EdgeInsets.all(20), child: Text("Error: $e"))),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, String helperText) {
    return SizedBox(
      width: 280,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
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
