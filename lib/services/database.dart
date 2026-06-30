import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:event_scan/models/barcode_model.dart';
import 'package:event_scan/models/scan_event_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/category_model.dart';
import 'collection_manager.dart';

class Database {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _configDocId = '.config';
  static const String _logsDocId = '.logs';
  static const String _scanEventsCollectionId = 'scan_events';
  static const String _scanHistoryCollectionId = 'scan_history';

  static String _getCurrentCollection() {
    final collection = CollectionManager.currentCollection;
    if (collection == null) {
      throw Exception('No collection selected. Please select a collection first.');
    }
    return collection;
  }

  static CollectionReference<Map<String, dynamic>> _eventCollection() {
    return _firestore.collection(_getCurrentCollection());
  }

  static CollectionReference<Map<String, dynamic>> _legacyScanLogCollection() {
    return _eventCollection().doc(_logsDocId).collection('entries');
  }

  static CollectionReference<Map<String, dynamic>> _scanLogDaysCollection() {
    return _eventCollection().doc(_logsDocId).collection('days');
  }

  static CollectionReference<Map<String, dynamic>> _scanLogCollectionForDateKey(String dateKey) {
    return _scanLogDaysCollection().doc(dateKey).collection(_scanEventsCollectionId);
  }

  static CollectionReference<Map<String, dynamic>> _userScanHistoryCollection(String barcode, String dateKey) {
    return _eventCollection().doc(barcode).collection('activity_days').doc(dateKey).collection(_scanHistoryCollectionId);
  }

  static bool _isSpecialDocId(String id) => id == _configDocId || id == _logsDocId;

  static String dateKeyFromDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static DateTime startOfDay(DateTime date) => DateTime(date.year, date.month, date.day);

  static DateTime endOfDay(DateTime date) => DateTime(date.year, date.month, date.day, 23, 59, 59, 999);

  static String formatDateTime(DateTime dateTime) {
    final month = _monthName(dateTime.month);
    final day = dateTime.day.toString().padLeft(2, '0');
    final hour24 = dateTime.hour;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final period = hour24 >= 12 ? 'PM' : 'AM';
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    return '$month $day, ${dateTime.year} ${hour12.toString().padLeft(2, '0')}:$minute $period';
  }

  static String _monthName(int month) {
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[month - 1];
  }

  static Future<Map<String, dynamic>> getSettings() async {
    try {
      final snapshot = await _eventCollection().doc(_configDocId).get();
      if (snapshot.exists) {
        return snapshot.data() as Map<String, dynamic>;
      }
      return {};
    } catch (e) {
      debugPrint('Error getting settings: $e');
      return {};
    }
  }

  static Future<void> saveSettings(Map<String, dynamic> settings) async {
    final collection = _getCurrentCollection();
    await CollectionManager.updateCollectionConfig(collection, settings);
  }

  static Future<int> getEventDayForDate(DateTime date) async {
    final settings = await getSettings();
    final startDate = (settings['startDate'] as Timestamp?)?.toDate() ?? date;
    return startOfDay(date).difference(startOfDay(startDate)).inDays + 1;
  }

  static Future<BarcodeModel?> checkBarcode(String barcode, String category) async {
    final userRef = _eventCollection().doc(barcode);
    final userDoc = await userRef.get();

    if (!userDoc.exists || _isSpecialDocId(userDoc.id)) {
      return null;
    }

    final existingUser = BarcodeModel.fromDocument(userDoc);
    final now = DateTime.now();
    final todayKey = dateKeyFromDate(now);
    final currentDay = await getEventDayForDate(now);

    final dayEventsSnapshot = await _scanLogCollectionForDateKey(todayKey)
        .where('barcode', isEqualTo: barcode)
        .where('category', isEqualTo: category)
        .get();
    final legacyEventsSnapshot = await _legacyScanLogCollection()
        .where('barcode', isEqualTo: barcode)
        .where('category', isEqualTo: category)
        .where('dateKey', isEqualTo: todayKey)
        .get();

    final lastEventDocs = <Map<String, dynamic>>[
      ...dayEventsSnapshot.docs.map((doc) => doc.data()),
      ...legacyEventsSnapshot.docs.map((doc) => doc.data()),
    ]..sort((a, b) {
        final aMillis = (a['createdAtMillis'] as num?)?.toInt() ?? 0;
        final bMillis = (b['createdAtMillis'] as num?)?.toInt() ?? 0;
        return bMillis.compareTo(aMillis);
      });

    final lastAction = lastEventDocs.isEmpty ? null : lastEventDocs.first['action']?.toString();
    final nextAction = lastAction == 'entry' ? 'exit' : 'entry';

    final scanned = <String, List<int>>{
      for (final entry in existingUser.scanned.entries) entry.key: List<int>.from(entry.value),
    };
    final categoryDays = scanned[category] ?? <int>[];
    if (!categoryDays.contains(currentDay)) {
      categoryDays.add(currentDay);
      categoryDays.sort();
    }
    scanned[category] = categoryDays;

    final eventRef = _scanLogCollectionForDateKey(todayKey).doc();
    final userHistoryRef = _userScanHistoryCollection(barcode, todayKey).doc(eventRef.id);
    final batch = _firestore.batch();
    final eventData = {
      'eventCollection': _getCurrentCollection(),
      'barcode': existingUser.code,
      'category': category,
      'action': nextAction,
      'dateKey': todayKey,
      'eventDay': currentDay,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMillis': now.millisecondsSinceEpoch,
      'title': existingUser.title,
      'subtitle': existingUser.subtitle,
      'extras': existingUser.extras.map((field) => field.toMap()).toList(),
    };

    batch.set(eventRef, eventData);
    batch.set(userHistoryRef, eventData);

    final lastActions = <String, String>{
      ...existingUser.lastActionByCategory,
      category: nextAction,
    };

    batch.set(userRef, {
      'scanned': scanned,
      'timestamp': FieldValue.serverTimestamp(),
      'lastScanAt': FieldValue.serverTimestamp(),
      'lastScanAction': nextAction,
      'lastScanCategory': category,
      'lastActionByCategory': lastActions,
    }, SetOptions(merge: true));

    await batch.commit();

    return existingUser.copyWith({
      'scanned': scanned,
      'timestamp': Timestamp.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch),
      'lastScanAt': Timestamp.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch),
      'lastScanAction': nextAction,
      'lastScanCategory': category,
      'lastActionByCategory': lastActions,
      'isScanned': false,
    });
  }

  static Future<Stream<QuerySnapshot>> getBarcodes({
    required String category,
    required bool isScanned,
    required int selectedDay,
  }) async {
    final collection = _getCurrentCollection();
    if (isScanned) {
      return _firestore
          .collection(collection)
          .where(FieldPath.documentId, isNotEqualTo: _configDocId)
          .where('scanned.$category', arrayContains: selectedDay)
          .snapshots();
    }
    return _firestore.collection(collection).snapshots();
  }

  static Future<void> resetBarcode(String barcode, String category) async {
    final docRef = _eventCollection().doc(barcode);
    final doc = await docRef.get();

    if (doc.exists && !_isSpecialDocId(doc.id)) {
      final data = doc.data() as Map<String, dynamic>;
      final scanned = (data['scanned'] as Map<String, dynamic>? ?? {}).map(
        (key, value) => MapEntry(key, (value as List).map((e) => e as int).toList()),
      );
      scanned.remove(category);

      await docRef.update({
        'scanned': scanned,
        'timestamp': DateTime.fromMillisecondsSinceEpoch(0),
      });
    }
  }

  static Future<void> setUpBarcodes(String path, String type) async {
    if (!kDebugMode) return;

    final batch = _firestore.batch();
    final collection = _eventCollection();
    final fileString = await rootBundle.loadString(path);
    final barcodes = fileString.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty);

    for (final barcode in barcodes) {
      batch.set(collection.doc(barcode), {
        'code': barcode,
        'title': '',
        'subtitle': type,
        'extras': [],
        'scanned': {},
        'timestamp': DateTime.fromMillisecondsSinceEpoch(0),
        'type': type,
      }, SetOptions(merge: true));
    }

    try {
      await batch.commit();
    } catch (error) {
      debugPrint(error.toString());
    }
  }

  static Future<int> calculateMaxDay() async {
    final settings = await getSettings();
    final startDate = (settings['startDate'] as Timestamp?)?.toDate() ?? DateTime.now();
    final endDate = (settings['endDate'] as Timestamp?)?.toDate() ?? startDate;
    return endOfDay(endDate).difference(startOfDay(startDate)).inDays + 1;
  }

  static Future<List<CategoryModel>> getCategories() async {
    try {
      final snapshot = await _eventCollection().doc(_configDocId).get();
      if (snapshot.exists) {
        final data = snapshot.data() as Map<String, dynamic>;
        final categoriesData = List<Map<String, dynamic>>.from(data['categories'] ?? []);
        return categoriesData.map(CategoryModel.fromMap).toList();
      }
      return [];
    } catch (e) {
      debugPrint('Error getting categories: $e');
      return [];
    }
  }

  static Future<void> addCategory(CategoryModel category) async {
    final categories = await getCategories();
    categories.add(category);
    await _eventCollection().doc(_configDocId).set({
      'categories': categories.map((cat) => cat.toMap()).toList(),
    }, SetOptions(merge: true));
  }

  static Future<void> deleteCategory(String category) async {
    final categories = await getCategories();
    categories.removeWhere((cat) => cat.name == category);
    await _eventCollection().doc(_configDocId).set({
      'categories': categories.map((cat) => cat.toMap()).toList(),
    }, SetOptions(merge: true));
  }

  static Future<Stream<QuerySnapshot<Object?>>> getBarcodesStream() async {
    return _eventCollection().snapshots();
  }

  static Stream<DocumentSnapshot> getSettingsStream() {
    try {
      return _eventCollection().doc(_configDocId).snapshots();
    } catch (e) {
      debugPrint('Error getting settings stream: $e');
      return const Stream.empty();
    }
  }

  static Future<void> updateUsers(List<BarcodeModel> usersData) async {
    final batch = _firestore.batch();
    final collection = _eventCollection();

    for (final userData in usersData) {
      final docRef = collection.doc(userData.code);
      final extrasData = userData.extras.map((field) => field.toMap()).toList();

      batch.set(docRef, {
        'code': userData.code,
        'title': userData.title,
        'subtitle': userData.subtitle,
        'extras': extrasData,
        'scanned': userData.scanned,
        'timestamp': FieldValue.serverTimestamp(),
        'lastActionByCategory': userData.lastActionByCategory,
        'lastScanAt': userData.lastScanAt,
        'lastScanCategory': userData.lastScanCategory,
        'lastScanAction': userData.lastScanAction,
      }, SetOptions(merge: true));
    }

    try {
      await batch.commit();
    } catch (error) {
      debugPrint(error.toString());
    }
  }

  static Future<List<BarcodeModel>> getUsers() async {
    final snapshot = await _eventCollection().get();
    return snapshot.docs
        .where((doc) => !_isSpecialDocId(doc.id))
        .map(BarcodeModel.fromDocument)
        .where((user) => user.code.isNotEmpty)
        .toList();
  }

  static Future<QuerySnapshot> getAttendees() async {
    return _eventCollection().where(FieldPath.documentId, isNotEqualTo: _configDocId).get();
  }

  static Future<List<ScanEventModel>> getScanEvents({
    DateTime? selectedDate,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final currentCollection = _getCurrentCollection();
    final events = <ScanEventModel>[];

    if (selectedDate != null) {
      final dateKey = dateKeyFromDate(selectedDate);
      final snapshot = await _scanLogCollectionForDateKey(dateKey).get();
      events.addAll(snapshot.docs.map(ScanEventModel.fromDocument));

      final legacySnapshot = await _legacyScanLogCollection().where('dateKey', isEqualTo: dateKey).get();
      events.addAll(legacySnapshot.docs.map(ScanEventModel.fromDocument));
    } else {
      final groupedSnapshot = await _firestore.collectionGroup(_scanEventsCollectionId)
          .where('eventCollection', isEqualTo: currentCollection)
          .get();

      for (final doc in groupedSnapshot.docs) {
        final event = ScanEventModel.fromDocument(doc);
        if (startDate != null && event.occurredAt.isBefore(startOfDay(startDate))) {
          continue;
        }
        if (endDate != null && event.occurredAt.isAfter(endOfDay(endDate))) {
          continue;
        }
        events.add(event);
      }

      final legacySnapshot = await _legacyScanLogCollection().get();
      for (final doc in legacySnapshot.docs) {
        final event = ScanEventModel.fromDocument(doc);
        if (startDate != null && event.occurredAt.isBefore(startOfDay(startDate))) {
          continue;
        }
        if (endDate != null && event.occurredAt.isAfter(endOfDay(endDate))) {
          continue;
        }
        events.add(event);
      }
    }

    events.sort((a, b) => b.createdAtMillis.compareTo(a.createdAtMillis));
    return events;
  }

  static Future<void> deleteUser(String id) async {
    await _eventCollection().doc(id).delete();
  }

  static Future<bool> deleteUsers(List<String> ids) async {
    final batch = _firestore.batch();

    for (final id in ids) {
      batch.delete(_eventCollection().doc(id));

      final userEvents = await _firestore.collectionGroup(_scanEventsCollectionId)
          .where('eventCollection', isEqualTo: _getCurrentCollection())
          .where('barcode', isEqualTo: id)
          .get();
      for (final eventDoc in userEvents.docs) {
        batch.delete(eventDoc.reference);
      }

      final legacyEvents = await _legacyScanLogCollection().where('barcode', isEqualTo: id).get();
      for (final eventDoc in legacyEvents.docs) {
        batch.delete(eventDoc.reference);
      }

      final userHistoryDays = await _eventCollection().doc(id).collection('activity_days').get();
      for (final dayDoc in userHistoryDays.docs) {
        final historyEntries = await dayDoc.reference.collection(_scanHistoryCollectionId).get();
        for (final entryDoc in historyEntries.docs) {
          batch.delete(entryDoc.reference);
        }
        batch.delete(dayDoc.reference);
      }
    }

    try {
      await batch.commit();
      return true;
    } catch (e) {
      debugPrint('Error deleting users: $e');
      return false;
    }
  }
}
