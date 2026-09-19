import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// Most Gemini/GPT-style image models settle around this many output tokens
// for a roughly 1024x1024 image — used only to turn a per-token price into a
// rough per-image estimate for display. Real cost varies by resolution/model,
// so this is a starting point, not a guarantee — verify against the actual
// OpenRouter usage dashboard after real traffic.
const int kAssumedTokensPerImage = 1290;

class ImageModelInfo {
  final String id;
  final String name;
  final double? estimatedCostPerImage;

  const ImageModelInfo({required this.id, required this.name, this.estimatedCostPerImage});

  String get priceLabel =>
      estimatedCostPerImage != null ? "~\$${estimatedCostPerImage!.toStringAsFixed(4)}/image" : "price n/a";
}

// Two-line dropdown item (name on top, price below) so neither gets cut off
// by an ellipsis — used with `itemHeight: null` on the DropdownButtonFormField
// so each item can size itself instead of being clipped to a single line.
DropdownMenuItem<String> modelDropdownItem(ImageModelInfo model) {
  return DropdownMenuItem(
    value: model.id,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(model.name, softWrap: true),
          Text(model.priceLabel, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    ),
  );
}

// Compact single-line version shown in the closed field — the rich two-line
// item (name + price) is only needed in the open menu list, where there's
// room for it. Without this, the closed field tries to render the same
// two-line item and overflows its fixed height.
List<Widget> modelSelectedItemBuilder(List<ImageModelInfo> models) {
  return models
      .map((m) => Align(
            alignment: Alignment.centerLeft,
            child: Text("${m.name}  ·  ${m.priceLabel}", overflow: TextOverflow.ellipsis),
          ))
      .toList();
}

Future<List<ImageModelInfo>> fetchImageModels() async {
  final res = await http.get(Uri.parse('https://openrouter.ai/api/v1/models'));
  if (res.statusCode != 200) {
    throw "OpenRouter returned HTTP ${res.statusCode}";
  }
  final data = jsonDecode(res.body) as Map<String, dynamic>;
  final models = (data['data'] as List)
      .where((m) {
        final outputs = (m['architecture']?['output_modalities'] as List?) ?? [];
        return outputs.contains('image') && !(m['id'] as String).startsWith('openrouter/auto');
      })
      .map((m) {
        final imageOutputPrice = double.tryParse(m['pricing']?['image_output']?.toString() ?? '');
        return ImageModelInfo(
          id: m['id'] as String,
          name: m['name'] as String,
          estimatedCostPerImage: imageOutputPrice != null ? imageOutputPrice * kAssumedTokensPerImage : null,
        );
      })
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return models;
}
