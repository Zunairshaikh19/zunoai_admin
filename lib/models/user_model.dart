import 'package:cloud_firestore/cloud_firestore.dart';

enum UserTier { free, paid }

class UserModel {
  final String uid;
  final String email;
  final String? displayName;
  final String? photoUrl;
  final int coins;
  final UserTier tier;
  final DateTime? premiumExpiresAt;
  final String referralCode;
  final int referralCount;
  final bool isBlocked;
  final DateTime? lastActivity;
  final String? fcmToken;

  UserModel({
    required this.uid,
    required this.email,
    this.displayName,
    this.photoUrl,
    required this.coins,
    required this.tier,
    this.premiumExpiresAt,
    required this.referralCode,
    required this.referralCount,
    required this.isBlocked,
    this.lastActivity,
    this.fcmToken,
  });

  factory UserModel.fromMap(Map<String, dynamic> data, String uid) {
    return UserModel(
      uid: uid,
      email: data['email'] ?? '',
      displayName: data['displayName'],
      photoUrl: data['photoUrl'],
      coins: data['coins'] ?? 0,
      tier: data['tier'] == 'paid' ? UserTier.paid : UserTier.free,
      premiumExpiresAt: (data['premiumExpiresAt'] as Timestamp?)?.toDate(),
      referralCode: data['referralCode'] ?? '',
      referralCount: data['referralCount'] ?? 0,
      isBlocked: data['isBlocked'] ?? false,
      lastActivity: (data['lastActivity'] as Timestamp?)?.toDate(),
      fcmToken: data['fcmToken'],
    );
  }
}
