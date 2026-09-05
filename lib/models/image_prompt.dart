class ImagePrompt {
  final String id;
  final String imageUrl;
  final String category;
  final String hiddenPrompt;
  final bool isPremium;

  ImagePrompt({
    required this.id,
    required this.imageUrl,
    required this.category,
    required this.hiddenPrompt,
    required this.isPremium,
  });

  factory ImagePrompt.fromMap(Map<String, dynamic> data, String id) {
    return ImagePrompt(
      id: id,
      imageUrl: data['imageUrl'] ?? '',
      category: data['category'] ?? '',
      hiddenPrompt: data['hiddenPrompt'] ?? '',
      isPremium: data['isPremium'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'imageUrl': imageUrl,
      'category': category,
      'hiddenPrompt': hiddenPrompt,
      'isPremium': isPremium,
    };
  }
}
