class ImagePrompt {
  final String id;
  final String imageUrl;
  final String category;
  final String hiddenPrompt;
  final bool isPremium;

  /// 'male' | 'female' | 'unisex' | 'couple' — which users see this prompt
  /// in their gallery, and (for 'couple') whether generation needs 2 photos.
  final String gender;

  /// Drafts (from bulk upload) start unpublished so the app never shows raw,
  /// un-reviewed data. Missing on old docs is treated as published (see
  /// ImagePrompt.fromMap default) so nothing already live gets hidden.
  final bool isPublished;

  /// Set by bulk upload when the prompt text still contains Midjourney-style
  /// parameters (--ar, --v, --sref, ...) that mean nothing to the Gemini
  /// model actually generating images — a flag for manual cleanup.
  final bool needsCleanup;

  ImagePrompt({
    required this.id,
    required this.imageUrl,
    required this.category,
    required this.hiddenPrompt,
    required this.isPremium,
    this.gender = 'unisex',
    this.isPublished = true,
    this.needsCleanup = false,
  });

  factory ImagePrompt.fromMap(Map<String, dynamic> data, String id) {
    return ImagePrompt(
      id: id,
      imageUrl: data['imageUrl'] ?? '',
      category: data['category'] ?? '',
      hiddenPrompt: data['hiddenPrompt'] ?? '',
      isPremium: data['isPremium'] ?? false,
      gender: data['gender'] ?? 'unisex',
      // Missing field = an old prompt from before this feature = already live.
      isPublished: data['isPublished'] ?? true,
      needsCleanup: data['needsCleanup'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'imageUrl': imageUrl,
      'category': category,
      'hiddenPrompt': hiddenPrompt,
      'isPremium': isPremium,
      'gender': gender,
      'isPublished': isPublished,
      'needsCleanup': needsCleanup,
    };
  }
}
