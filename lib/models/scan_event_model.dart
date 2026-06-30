import 'package:cloud_firestore/cloud_firestore.dart';

class ScanEventModel {
  final String id;
  final String barcode;
  final String category;
  final String action;
  final String dateKey;
  final int eventDay;
  final int createdAtMillis;
  final Timestamp? createdAt;
  final String title;
  final String subtitle;

  const ScanEventModel({
    required this.id,
    required this.barcode,
    required this.category,
    required this.action,
    required this.dateKey,
    required this.eventDay,
    required this.createdAtMillis,
    required this.createdAt,
    required this.title,
    required this.subtitle,
  });

  DateTime get occurredAt {
    if (createdAt != null) {
      return createdAt!.toDate();
    }
    return DateTime.fromMillisecondsSinceEpoch(createdAtMillis);
  }

  factory ScanEventModel.fromDocument(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? const <String, dynamic>{};
    return ScanEventModel(
      id: doc.id,
      barcode: data['barcode']?.toString() ?? '',
      category: data['category']?.toString() ?? '',
      action: data['action']?.toString() ?? 'entry',
      dateKey: data['dateKey']?.toString() ?? '',
      eventDay: (data['eventDay'] as num?)?.toInt() ?? 1,
      createdAtMillis: (data['createdAtMillis'] as num?)?.toInt() ?? 0,
      createdAt: data['createdAt'] as Timestamp?,
      title: data['title']?.toString() ?? '',
      subtitle: data['subtitle']?.toString() ?? '',
    );
  }
}
