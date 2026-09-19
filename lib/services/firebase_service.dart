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

  Future<void> bulkUploadPrompts(
    List<Map<String, dynamic>> jsonList, 
    Function(int, int) onProgress, {
    bool Function()? shouldCancel,
  }) async {
    int count = 0;
    int total = jsonList.length;

    for (var data in jsonList) {
      if (shouldCancel != null && shouldCancel()) {
        debugPrint("Bulk upload cancelled by user");
        break;
      }
      try {
        String imageUrl = data['imageUrl'] ?? '';
        
        // If image URL is from external source, download and re-upload to ImgBB
        if (imageUrl.isNotEmpty && imageUrl.startsWith('http') && !imageUrl.contains('imgbb.com')) {
          final response = await http.get(Uri.parse(imageUrl));
          if (response.statusCode == 200) {
            imageUrl = await uploadImageWeb(response.bodyBytes);
          }
        }

        final prompt = ImagePrompt(
          id: '',
          imageUrl: imageUrl,
          category: data['category'] ?? 'General',
          hiddenPrompt: data['hiddenPrompt'] ?? '',
          isPremium: data['isPremium'] ?? false,
        );

        await addPrompt(prompt);
        count++;
        onProgress(count, total);
      } catch (e) {
        debugPrint("Failed to upload prompt: $e");
        // Continue with others
      }
    }
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
