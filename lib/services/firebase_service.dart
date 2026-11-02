import 'dart:async';
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
  // The secret prompt text lives in `promptSecrets/{id}` (admin/server-only per
  // firestore.rules). The public `prompts/{id}` doc must never hold it, because
  // anyone — guests included — can read `prompts`.
  Future<void> addPrompt(ImagePrompt prompt) async {
    final ref = _firestore.collection('prompts').doc();
    final batch = _firestore.batch();
    batch.set(ref, prompt.toMap()); // public fields only
    batch.set(_firestore.collection('promptSecrets').doc(ref.id), {
      'hiddenPrompt': prompt.hiddenPrompt,
    });
    await batch.commit();
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
  // it on our Cloudflare R2 bucket — see supabase/functions/mirror-image in the
  // main app repo. Same Supabase project as the app's generate-image function,
  // so it shares its R2_* / FIREBASE_SERVICE_ACCOUNT_KEY secrets already.
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

  /// Everything needed to rebuild the prompts: the public `prompts` docs and the
  /// `promptSecrets` docs, as one JSON string. Used for the backup the admin
  /// downloads BEFORE running [migratePromptSecrets] (which deletes the legacy
  /// public copy of the secret text).
  Future<String> exportPromptsBackupJson() async {
    final prompts = await _firestore.collection('prompts').get();
    final secrets = await _firestore.collection('promptSecrets').get();
    final data = {
      'exportedAt': DateTime.now().toIso8601String(),
      'prompts': {for (final d in prompts.docs) d.id: d.data()},
      'promptSecrets': {for (final d in secrets.docs) d.id: d.data()},
    };
    return const JsonEncoder.withIndent('  ').convert(
      jsonDecode(jsonEncode(data, toEncodable: (o) => o.toString())),
    );
  }

  static const String _splitPromptsUrl = "https://ylenfbneddyuzrkckaul.supabase.co/functions/v1/split-prompts";

  /// Runs the `split-prompts` edge function: moves every prompt's secret text
  /// into `promptSecrets` and removes it from the public `prompts` doc.
  /// Safe to run again. Returns "migrated, skipped" counts.
  Future<({int migrated, int skipped})> migratePromptSecrets() async {
    final user = _auth.currentUser;
    if (user == null) throw "Not authenticated";
    final idToken = await user.getIdToken();

    final res = await http.post(
      Uri.parse(_splitPromptsUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $idToken',
      },
    );

    Map<String, dynamic> data;
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw "split-prompts returned an unexpected response (HTTP ${res.statusCode})";
    }
    if (res.statusCode == 200 && data['success'] == true) {
      return (migrated: (data['migrated'] as num).toInt(), skipped: (data['skipped'] as num).toInt());
    }
    throw data['error'] ?? "split-prompts failed (HTTP ${res.statusCode})";
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
    final secretsSnapshot = await _firestore.collection('promptSecrets').get();
    final seenHiddenPrompts = <String>{
      // Legacy copies still sitting in the public `prompts` docs...
      for (final doc in existingSnapshot.docs)
        if ((doc.data()['hiddenPrompt'] as String? ?? '').trim().isNotEmpty)
          (doc.data()['hiddenPrompt'] as String).trim(),
      // ...and the real (migrated / new) ones in `promptSecrets`.
      for (final doc in secretsSnapshot.docs)
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

        // Mirror external images to R2 via a server-side Supabase function
        // instead of downloading them in-browser: Flutter Web can't read the
        // bytes of an image from a host that doesn't send CORS headers (most
        // buckets don't — they're built for <img> tags, not fetch()), so a
        // direct browser download throws "Failed to fetch" for those. The
        // server-side function has no such restriction. If it still fails for
        // some other reason (source genuinely offline, etc.), fall back to
        // the original URL rather than losing the whole prompt.
        if (imageUrl.isNotEmpty && imageUrl.startsWith('http')) {
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
    final batch = _firestore.batch();
    batch.update(_firestore.collection('prompts').doc(id), {
      'imageUrl': imageUrl,
      'category': category,
      'gender': gender,
      'isPremium': isPremium,
      'needsCleanup': textNeedsCleanup(hiddenPrompt),
      // Scrub any legacy public copy of the secret text for this prompt.
      'hiddenPrompt': FieldValue.delete(),
    });
    batch.set(
      _firestore.collection('promptSecrets').doc(id),
      {'hiddenPrompt': hiddenPrompt},
      SetOptions(merge: true),
    );
    await batch.commit();
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
    final batch = _firestore.batch();
    batch.delete(_firestore.collection('prompts').doc(id));
    batch.delete(_firestore.collection('promptSecrets').doc(id));
    await batch.commit();
  }

  Future<void> deleteMultiplePrompts(List<String> ids) async {
    final batch = _firestore.batch();
    for (var id in ids) {
      batch.delete(_firestore.collection('prompts').doc(id));
      batch.delete(_firestore.collection('promptSecrets').doc(id));
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

  /// Public prompt docs merged with their secret text from `promptSecrets`.
  /// A prompt not migrated yet still falls back to its legacy `hiddenPrompt`
  /// field, so the admin list keeps working before and after running the
  /// `split-prompts` migration.
  Stream<List<ImagePrompt>> getPrompts() {
    late final StreamController<List<ImagePrompt>> controller;
    StreamSubscription? promptsSub;
    StreamSubscription? secretsSub;
    QuerySnapshot<Map<String, dynamic>>? latestPrompts;
    QuerySnapshot<Map<String, dynamic>>? latestSecrets;

    void emit() {
      final prompts = latestPrompts;
      final secrets = latestSecrets;
      if (prompts == null || secrets == null) return;
      final secretText = <String, String>{
        for (final d in secrets.docs) d.id: (d.data()['hiddenPrompt'] as String? ?? ''),
      };
      controller.add(prompts.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        final secret = secretText[doc.id];
        if (secret != null && secret.isNotEmpty) data['hiddenPrompt'] = secret;
        return ImagePrompt.fromMap(data, doc.id);
      }).toList());
    }

    controller = StreamController<List<ImagePrompt>>(
      onListen: () {
        promptsSub = _firestore.collection('prompts').snapshots().listen(
          (s) {
            latestPrompts = s;
            emit();
          },
          onError: controller.addError,
        );
        secretsSub = _firestore.collection('promptSecrets').snapshots().listen(
          (s) {
            latestSecrets = s;
            emit();
          },
          onError: controller.addError,
        );
      },
      onCancel: () async {
        await promptsSub?.cancel();
        await secretsSub?.cancel();
      },
    );
    return controller.stream;
  }

  static const String _uploadImageUrl = "https://ylenfbneddyuzrkckaul.supabase.co/functions/v1/upload-image";

  /// Uploads a template image through the `upload-image` edge function
  /// (admin purpose: bigger size limit) which stores it on Cloudflare R2.
  /// No storage key lives in the admin build any more.
  Future<String> uploadImageWeb(Uint8List bytes) async {
    final user = _auth.currentUser;
    if (user == null) throw "Not authenticated";
    final idToken = await user.getIdToken();

    final res = await http.post(
      Uri.parse(_uploadImageUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $idToken',
      },
      body: jsonEncode({'imageBase64': base64Encode(bytes), 'purpose': 'prompt'}),
    );

    Map<String, dynamic> data;
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw "Upload returned an unexpected response (HTTP ${res.statusCode})";
    }
    if (res.statusCode == 200 && data['success'] == true) {
      return data['url'] as String;
    }
    throw data['error'] ?? "Upload failed (HTTP ${res.statusCode})";
  }

  static const String _migrateImagesUrl = "https://ylenfbneddyuzrkckaul.supabase.co/functions/v1/migrate-prompt-images";

  /// Moves every prompt's template image from ImgBB to R2 by calling the
  /// `migrate-prompt-images` function page by page until it is done. Safe to
  /// run again: images already on R2 are skipped. Prompts whose old image can
  /// no longer be fetched are flagged `needsCleanup`.
  Future<({int migrated, int skipped, int failed})> migratePromptImages({
    void Function(int migrated, int skipped, int failed)? onProgress,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw "Not authenticated";

    var migrated = 0, skipped = 0, failed = 0;
    String? pageToken;
    do {
      final idToken = await user.getIdToken();
      Map<String, dynamic>? data;
      Object? lastError;
      // One retry per page for transient network / cold-start errors.
      for (var attempt = 0; attempt < 2 && data == null; attempt++) {
        try {
          final res = await http.post(
            Uri.parse(_migrateImagesUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode({if (pageToken != null) 'pageToken': pageToken}),
          );
          final parsed = jsonDecode(res.body) as Map<String, dynamic>;
          if (res.statusCode == 200 && parsed['success'] == true) {
            data = parsed;
          } else {
            lastError = parsed['error'] ?? "HTTP ${res.statusCode}";
          }
        } catch (e) {
          lastError = e;
        }
      }
      if (data == null) throw "Image migration rukk gayi: $lastError (jo ho chuki woh save hai, dobara chalao)";

      migrated += (data['migrated'] as num).toInt();
      skipped += (data['skipped'] as num).toInt();
      failed += (data['failed'] as num).toInt();
      onProgress?.call(migrated, skipped, failed);
      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null);

    return (migrated: migrated, skipped: skipped, failed: failed);
  }

  // Our own R2 public base. A prompt whose imageUrl starts with this is done.
  // (If the R2 custom domain is added later, add the new base here too.)
  static const List<String> _ownImageBases = [
    "https://pub-4eca0f1f940e48efb441f5b810103262.r2.dev/",
  ];

  static bool _isOwnImage(String url) => _ownImageBases.any(url.startsWith);

  /// Repairs template images using the original import JSON
  /// (`all_prompts_database.json`). For every prompt whose image is not on our
  /// R2 yet, finds the JSON entry with the same hidden prompt text and copies
  /// that entry's original image to R2 (server-side, via mirror-image).
  /// Only `imageUrl` / `legacyImageUrl` change; publish/premium/gender etc. are
  /// untouched. Cost: one read per prompt + one per secret, one write per fix.
  Future<({int fixed, int alreadyOk, int noMatch, int failed})> repairImagesFromJson(
    List<Map<String, dynamic>> jsonList, {
    void Function(int fixed, int alreadyOk, int noMatch, int failed, int total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final sourceByText = <String, String>{};
    for (final e in jsonList) {
      final text = (e['hiddenPrompt'] ?? '').toString().trim();
      final url = (e['imageUrl'] ?? '').toString();
      if (text.isNotEmpty && url.startsWith('http')) sourceByText.putIfAbsent(text, () => url);
    }

    final prompts = await _firestore.collection('prompts').get();
    final secrets = await _firestore.collection('promptSecrets').get();
    final hiddenById = {
      for (final d in secrets.docs) d.id: (d.data()['hiddenPrompt'] ?? '').toString().trim(),
    };

    var fixed = 0, alreadyOk = 0, noMatch = 0, failed = 0;
    final total = prompts.docs.length;
    final todo = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final d in prompts.docs) {
      final url = (d.data()['imageUrl'] ?? '').toString();
      if (_isOwnImage(url)) {
        alreadyOk++;
      } else {
        todo.add(d);
      }
    }
    onProgress?.call(fixed, alreadyOk, noMatch, failed, total);

    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (shouldCancel != null && shouldCancel()) return;
        if (next >= todo.length) return;
        final d = todo[next++];
        final hidden = hiddenById[d.id] ?? '';
        final source = sourceByText[hidden];
        if (source == null) {
          noMatch++;
        } else {
          try {
            final newUrl = await _mirrorImageServerSide(source);
            final old = (d.data()['imageUrl'] ?? '').toString();
            await _firestore.collection('prompts').doc(d.id).update({
              'imageUrl': newUrl,
              if (old.isNotEmpty) 'legacyImageUrl': old,
              // Earlier failed migration runs wrongly set this; recompute from the text.
              'needsCleanup': textNeedsCleanup(hidden),
            });
            fixed++;
          } catch (e) {
            debugPrint("Repair failed for ${d.id}: $e");
            failed++;
          }
        }
        onProgress?.call(fixed, alreadyOk, noMatch, failed, total);
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    return (fixed: fixed, alreadyOk: alreadyOk, noMatch: noMatch, failed: failed);
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
