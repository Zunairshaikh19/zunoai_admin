import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../models/user_model.dart';
import '../models/image_prompt.dart';
import '../models/support_message.dart';

class FirebaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ImgBB API Key — pass at build time with:
  //   flutter build web --dart-define=IMGBB_API_KEY=your_key
  // (rotate the old key on imgbb.com since it was previously committed to source control)
  static const String _imgBBKey = String.fromEnvironment('IMGBB_API_KEY');

  // --- Auth ---
  Future<UserCredential> adminLogin(String email, String password) async {
    final credential = await _auth.signInWithEmailAndPassword(email: email, password: password);
    final uid = credential.user?.uid;
    if (uid == null || !await isAdmin(uid)) {
      await _auth.signOut();
      throw FirebaseAuthException(
        code: 'not-admin',
        message: 'This account does not have admin access.',
      );
    }
    return credential;
  }

  Future<bool> isAdmin(String uid) async {
    final doc = await _firestore.collection('admins').doc(uid).get();
    return doc.exists;
  }

  // --- Users ---
  Stream<List<UserModel>> getAllUsers() {
    return _firestore.collection('users').snapshots().map((snapshot) =>
        snapshot.docs.map((doc) => UserModel.fromMap(doc.data(), doc.id)).toList());
  }

  Future<void> toggleUserBlock(String uid, bool block) async {
    await _firestore.collection('users').doc(uid).update({'isBlocked': block});
  }

  Future<void> giveUserCoins(String uid, int amount, {String? reason}) async {
    await _firestore.collection('users').doc(uid).update({
      'coins': FieldValue.increment(amount),
    });
    // Audit trail: who granted what, when, and why — so a coin balance can
    // always be explained later.
    await _firestore.collection('coinAdjustments').add({
      'uid': uid,
      'amount': amount,
      'reason': reason ?? 'Manual grant',
      'adminEmail': _auth.currentUser?.email,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  /// Manually grants or revokes premium — the escape hatch for fixing a
  /// customer whose purchase didn't activate correctly. `days == null`
  /// revokes premium immediately.
  Future<void> setPremiumTier(String uid, {int? days}) async {
    if (days == null) {
      await _firestore.collection('users').doc(uid).update({
        'tier': 'free',
        'premiumExpiresAt': null,
      });
      return;
    }
    await _firestore.collection('users').doc(uid).update({
      'tier': 'paid',
      'premiumExpiresAt': Timestamp.fromDate(DateTime.now().add(Duration(days: days))),
    });
  }

  // --- Prompts ---
  Future<void> addPrompt(ImagePrompt prompt) async {
    await _firestore.collection('prompts').add(prompt.toMap());
  }

  // Midjourney-style parameters that mean nothing to the Gemini model we
  // actually generate with — if these are still in the text, the prompt is
  // flagged for manual cleanup rather than auto-edited (admin reviews and
  // fixes the wording by hand, then publishes).
  static final RegExp _midjourneyFlagPattern = RegExp(r'--(ar|v|stylize|sref|raw|profile|chaos|weird|niji|q|seed|style)\b', caseSensitive: false);

  static final RegExp _maleWordPattern = RegExp(r'\b(man|men|boy|boys|male|guy|guys|groom|husband|father|dad)\b', caseSensitive: false);
  static final RegExp _femaleWordPattern = RegExp(r'\b(woman|women|girl|girls|female|lady|ladies|bride|wife|mother|mom)\b', caseSensitive: false);

  /// Best-effort gender tag from the prompt's own wording — used only to
  /// pre-fill the tag so admin doesn't have to set every one by hand; still
  /// editable afterward. Mentions of both -> 'couple', one -> that gender,
  /// neither -> 'unisex'.
  static String detectGenderFromText(String text) {
    final hasMale = _maleWordPattern.hasMatch(text);
    final hasFemale = _femaleWordPattern.hasMatch(text);
    if (hasMale && hasFemale) return 'couple';
    if (hasMale) return 'male';
    if (hasFemale) return 'female';
    return 'unisex';
  }

  static bool textNeedsCleanup(String text) => _midjourneyFlagPattern.hasMatch(text);

  // Supabase edge function that downloads an image server-side and re-hosts
  // it on ImgBB — see supabase/functions/mirror-image in the main app repo.
  // Same Supabase project as the app's generate-image function, so it shares
  // its IMGBB_API_KEY / FIREBASE_SERVICE_ACCOUNT_KEY secrets already.
  static const String _mirrorImageUrl = "https://ylenfbneddyuzrkckaul.supabase.co/functions/v1/mirror-image";

  Future<String> _mirrorImageServerSide(String imageUrl) async {
    final user = _auth.currentUser;
    if (user == null) throw "Not authenticated";
    final idToken = await user.getIdToken();

    final res = await http.post(
      Uri.parse(_mirrorImageUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $idToken',
      },
      body: jsonEncode({'imageUrl': imageUrl}),
    );

    Map<String, dynamic> data;
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw "Mirror function returned an unexpected response (HTTP ${res.statusCode})";
    }

    if (res.statusCode == 200 && data['success'] == true) {
      return data['imageUrl'] as String;
    }
    throw data['error'] ?? "Mirror function failed (HTTP ${res.statusCode})";
  }

  /// Bulk-imports prompts from a JSON list, skipping anything whose
  /// `hiddenPrompt` text already exists (either already live in Firestore, or
  /// earlier in this same batch) so re-running an import — or importing an
  /// overlapping file — never creates duplicates. Every prompt this creates
  /// is a draft (`isPublished: false`): it never shows in the app until an
  /// admin reviews and publishes it here. `needsCleanup` flags prompts whose
  /// text still has raw Midjourney parameters, and `gender` is pre-filled by
  /// keyword-matching the prompt text — both are just starting points the
  /// admin can still edit before publishing.
  Future<BulkUploadResult> bulkUploadPrompts(
    List<Map<String, dynamic>> jsonList,
    Function(int, int) onProgress, {
    bool Function()? shouldCancel,
  }) async {
    int processed = 0;
    int added = 0;
    int skippedDuplicate = 0;
    int flaggedForCleanup = 0;
    final total = jsonList.length;

    // Existing prompts predate any JSON `id` scheme (some have no `id` field
    // at all), so the only reliable dedup key across old and new data is the
    // hiddenPrompt text itself.
    final existingSnapshot = await _firestore.collection('prompts').get();
    final seenHiddenPrompts = <String>{
      for (final doc in existingSnapshot.docs)
        if ((doc.data()['hiddenPrompt'] as String? ?? '').trim().isNotEmpty)
          (doc.data()['hiddenPrompt'] as String).trim(),
    };

    for (var data in jsonList) {
      if (shouldCancel != null && shouldCancel()) {
        debugPrint("Bulk upload cancelled by user");
        break;
      }
      processed++;
      try {
        final hiddenPrompt = (data['hiddenPrompt'] ?? '').toString().trim();

        if (hiddenPrompt.isEmpty || seenHiddenPrompts.contains(hiddenPrompt)) {
          skippedDuplicate++;
          onProgress(processed, total);
          continue;
        }
        // Reserve it immediately so a duplicate later in the same batch is
        // also caught, not just duplicates against pre-existing docs.
        seenHiddenPrompts.add(hiddenPrompt);

        String imageUrl = data['imageUrl'] ?? '';

        // Mirror external images to ImgBB via a server-side Supabase function
        // instead of downloading them in-browser: Flutter Web can't read the
        // bytes of an image from a host that doesn't send CORS headers (most
        // buckets don't — they're built for <img> tags, not fetch()), so a
        // direct browser download throws "Failed to fetch" for those. The
        // server-side function has no such restriction. If it still fails for
        // some other reason (source genuinely offline, etc.), fall back to
        // the original URL rather than losing the whole prompt.
        if (imageUrl.isNotEmpty && imageUrl.startsWith('http') && !imageUrl.contains('imgbb.com')) {
          try {
            imageUrl = await _mirrorImageServerSide(imageUrl);
          } catch (e) {
            debugPrint("Could not mirror image, keeping original URL ($imageUrl): $e");
          }
        }

        final needsCleanup = textNeedsCleanup(hiddenPrompt);
        if (needsCleanup) flaggedForCleanup++;

        final prompt = ImagePrompt(
          id: '',
          imageUrl: imageUrl,
          category: data['category'] ?? 'General',
          hiddenPrompt: hiddenPrompt,
          isPremium: data['isPremium'] ?? false,
          gender: detectGenderFromText(hiddenPrompt),
          isPublished: false,
          needsCleanup: needsCleanup,
        );

        await addPrompt(prompt);
        added++;
        onProgress(processed, total);
      } catch (e) {
        debugPrint("Failed to upload prompt: $e");
        // Continue with others
      }
    }

    debugPrint(
      "Bulk upload done: $added added, $skippedDuplicate skipped (duplicate), "
      "$flaggedForCleanup flagged for cleanup, out of $total total.",
    );

    return BulkUploadResult(
      total: total,
      added: added,
      skippedDuplicate: skippedDuplicate,
      flaggedForCleanup: flaggedForCleanup,
    );
  }

  /// New prompts land as drafts (see [bulkUploadPrompts]); this is how an
  /// admin makes one visible in the app after reviewing it.
  Future<void> updatePromptPublished(String id, bool isPublished) async {
    await _firestore.collection('prompts').doc(id).update({'isPublished': isPublished});
  }

  /// Flags a prompt for manual cleanup because its image failed to load in
  /// the grid (broken/dead source link) — not just for leftover Midjourney
  /// text. Called once, client-side, the first time `Image.network` reports
  /// an error for that card, so broken-image prompts surface in the same
  /// "Needs Cleanup" queue instead of silently sitting broken in the app.
  Future<void> flagImageNeedsCleanup(String id) async {
    await _firestore.collection('prompts').doc(id).update({'needsCleanup': true});
  }

  /// Full manual edit of an existing prompt — used to fix whatever put it in
  /// "Needs Cleanup": swap in a working image, rewrite the prompt text (e.g.
  /// strip Midjourney parameters), and adjust category/gender/premium.
  /// `needsCleanup` is recomputed from the saved text so a prompt that's been
  /// fixed drops out of that filter on its own.
  Future<void> updatePromptDetails(
    String id, {
    required String imageUrl,
    required String category,
    required String hiddenPrompt,
    required String gender,
    required bool isPremium,
  }) async {
    await _firestore.collection('prompts').doc(id).update({
      'imageUrl': imageUrl,
      'category': category,
      'hiddenPrompt': hiddenPrompt,
      'gender': gender,
      'isPremium': isPremium,
      'needsCleanup': textNeedsCleanup(hiddenPrompt),
    });
  }

  Future<void> updateMultiplePromptsPublished(List<String> ids, bool isPublished) async {
    final batch = _firestore.batch();
    for (var id in ids) {
      batch.update(_firestore.collection('prompts').doc(id), {'isPublished': isPublished});
    }
    await batch.commit();
  }

  Future<void> updatePromptGender(String id, String gender) async {
    await _firestore.collection('prompts').doc(id).update({'gender': gender});
  }

  Future<void> deletePrompt(String id) async {
    await _firestore.collection('prompts').doc(id).delete();
  }

  Future<void> deleteMultiplePrompts(List<String> ids) async {
    final batch = _firestore.batch();
    for (var id in ids) {
      batch.delete(_firestore.collection('prompts').doc(id));
    }
    await batch.commit();
  }

  Future<void> updatePromptPremiumStatus(String id, bool isPremium) async {
    await _firestore.collection('prompts').doc(id).update({'isPremium': isPremium});
  }

  Future<void> updateMultiplePromptsPremiumStatus(List<String> ids, bool isPremium) async {
    final batch = _firestore.batch();
    for (var id in ids) {
      batch.update(_firestore.collection('prompts').doc(id), {'isPremium': isPremium});
    }
    await batch.commit();
  }

  Stream<List<ImagePrompt>> getPrompts() {
    return _firestore.collection('prompts').snapshots().map((snapshot) =>
        snapshot.docs.map((doc) => ImagePrompt.fromMap(doc.data(), doc.id)).toList());
  }

  Future<String> uploadImageWeb(Uint8List bytes) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('https://api.imgbb.com/1/upload?key=$_imgBBKey'),
    );
    request.files.add(http.MultipartFile.fromBytes('image', bytes, filename: 'prompt.jpg'));

    final response = await request.send();
    if (response.statusCode == 200) {
      final resData = await response.stream.bytesToString();
      final json = jsonDecode(resData);
      return json['data']['url'];
    } else {
      throw "Upload failed";
    }
  }

  // --- Support ---
  Stream<List<Map<String, dynamic>>> getSupportTickets() {
    return _firestore.collection('support_tickets').orderBy('lastTimestamp', descending: true).snapshots().map((snapshot) =>
        snapshot.docs.map((doc) => {...doc.data(), 'id': doc.id}).toList());
  }

  Stream<List<SupportMessage>> getMessages(String ticketId) {
    return _firestore.collection('support_tickets').doc(ticketId).collection('messages').orderBy('timestamp', descending: true).snapshots().map((snapshot) =>
        snapshot.docs.map((doc) => SupportMessage.fromMap(doc.data(), doc.id)).toList());
  }

  Future<void> setTicketStatus(String ticketId, String status) async {
    await _firestore.collection('support_tickets').doc(ticketId).update({'status': status});
  }

  Future<void> sendAdminMessage(String ticketId, String text) async {
    final message = SupportMessage(
      id: '',
      senderId: 'admin',
      text: text,
      timestamp: DateTime.now(),
      isAdmin: true,
    );
    
    await _firestore.collection('support_tickets').doc(ticketId).collection('messages').add(message.toMap());
    await _firestore.collection('support_tickets').doc(ticketId).update({
      'lastMessage': text,
      'lastTimestamp': FieldValue.serverTimestamp(),
    });
  }

  // --- Marketing & Notifications ---

  Future<void> sendNotificationToUser({
    required String uid,
    required String title,
    required String message,
    int? coinReward,
  }) async {
    final data = {
      'title': title,
      'message': message,
      'timestamp': FieldValue.serverTimestamp(),
      'isRead': false,
      'coinReward': coinReward,
    };
    await _firestore.collection('users').doc(uid).collection('notifications').add(data);
    
    if (coinReward != null && coinReward > 0) {
      await giveUserCoins(uid, coinReward);
    }
  }

  Future<void> sendMassNotification({
    required List<String> uids,
    required String title,
    required String message,
    int? coinReward,
  }) async {
    final batch = _firestore.batch();
    for (var uid in uids) {
      final ref = _firestore.collection('users').doc(uid).collection('notifications').doc();
      batch.set(ref, {
        'title': title,
        'message': message,
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
        'coinReward': coinReward,
      });
      if (coinReward != null && coinReward > 0) {
        batch.update(_firestore.collection('users').doc(uid), {'coins': FieldValue.increment(coinReward)});
      }
    }
    await batch.commit();
  }

  Future<void> sendGlobalNotification({
    required String title,
    required String message,
    int? coinReward,
  }) async {
    final users = await _firestore.collection('users').get();
    final uids = users.docs.map((d) => d.id).toList();
    
    for (var i = 0; i < uids.length; i += 250) {
      final chunk = uids.sublist(i, i + 250 > uids.length ? uids.length : i + 250);
      await sendMassNotification(uids: chunk, title: title, message: message, coinReward: coinReward);
    }
  }
}

class BulkUploadResult {
  final int total;
  final int added;
  final int skippedDuplicate;
  final int flaggedForCleanup;

  BulkUploadResult({
    required this.total,
    required this.added,
    required this.skippedDuplicate,
    required this.flaggedForCleanup,
  });
}
