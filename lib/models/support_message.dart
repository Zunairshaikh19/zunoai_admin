import 'package:cloud_firestore/cloud_firestore.dart';

class SupportMessage {
  final String id;
  final String senderId;
  final String text;
  final String? attachmentUrl;
  final DateTime timestamp;
  final bool isAdmin;

  SupportMessage({
    required this.id,
    required this.senderId,
    required this.text,
    this.attachmentUrl,
    required this.timestamp,
    required this.isAdmin,
  });

  factory SupportMessage.fromMap(Map<String, dynamic> data, String id) {
    return SupportMessage(
      id: id,
      senderId: data['senderId'] ?? '',
      text: data['text'] ?? '',
      attachmentUrl: data['attachmentUrl'],
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isAdmin: data['isAdmin'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'senderId': senderId,
      'text': text,
      'attachmentUrl': attachmentUrl,
      'timestamp': FieldValue.serverTimestamp(),
      'isAdmin': isAdmin,
    };
  }
}
