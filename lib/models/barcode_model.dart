import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class ExtraField {
  final String key;
  final String value;
  final IconData? icon;

  ExtraField({required this.key, this.value='', this.icon});

  factory ExtraField.fromEntry(String key, dynamic data) {
    if (data is Map<String, dynamic>) {
      final iconCode = data['icon'];
      return ExtraField(
        key: key,
        value: data['value']?.toString() ?? '',
        icon: iconCode != null ? _iconFromCodePoint(iconCode as int) : null,
      );
    }
    return ExtraField(key: key, value: data?.toString() ?? '');
  }

  Map<String, dynamic> toMap() => {
    'key': key,
    'value': value,
    if (icon != null) 'icon': icon!.codePoint,
  };

  ExtraField copyWith({String? key, String? value, IconData? icon}) =>
      ExtraField(key: key ?? this.key, value: value ?? this.value, icon: icon ?? this.icon);

  static List<ExtraField> fromDynamic(dynamic data) {
    if (data is List<ExtraField>) return data;
    if (data is List) {
      return data.map((item) {
        if (item is ExtraField) return item;
        if (item is Map<String, dynamic>) {
          return ExtraField.fromEntry(item['key'] ?? '', item);
        }
        return ExtraField(key: 'Unknown', value: item?.toString() ?? '');
      }).toList();
    }
    return <ExtraField>[];
  }
}

IconData _iconFromCodePoint(int codePoint) {
  // ignore: non_const_argument_for_const_parameter
  return IconData(codePoint, fontFamily: 'MaterialIcons');
}

class BarcodeModel {
  final String code;
  final String title;
  final String subtitle;
  final List<ExtraField> extras;
  final Map<String, List<int>> scanned;
  final Timestamp timestamp;
  final Map<String, String> lastActionByCategory;
  final Timestamp? lastScanAt;
  final String? lastScanCategory;
  final String? lastScanAction;
  late bool? isScanned;

  BarcodeModel({
    required this.code,
    required this.title,
    required this.subtitle,
    required this.extras,
    required this.scanned,
    required this.timestamp,
    this.lastActionByCategory = const {},
    this.lastScanAt,
    this.lastScanCategory,
    this.lastScanAction,
    this.isScanned,
  });

  factory BarcodeModel.fromDocument(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    
    return BarcodeModel(
      code: data?['code'] ?? '',
      title: data?['title'] ?? '',
      subtitle: data?['subtitle'] ?? '',
      extras: ExtraField.fromDynamic(data?['extras']),
      scanned: (data?['scanned'] as Map<String, dynamic>? ?? {}).map(
        (key, value) => MapEntry(key, (value as List).map((e) => e as int).toList()),
      ),
      timestamp: data?['timestamp'] ?? Timestamp.now(),
      lastActionByCategory: (data?['lastActionByCategory'] as Map<String, dynamic>? ?? {})
          .map((key, value) => MapEntry(key, value.toString())),
      lastScanAt: data?['lastScanAt'] as Timestamp?,
      lastScanCategory: data?['lastScanCategory']?.toString(),
      lastScanAction: data?['lastScanAction']?.toString(),
    );
  }

  factory BarcodeModel.from(dynamic data, {bool strict = false}) {
    if (strict) {
      if (data is! Map<String, dynamic>) throw ArgumentError('Expected Map<String, dynamic>');
      final required = ['code', 'title', 'subtitle', 'extras', 'scanned'];
      final missing = required.where((key) => !data.containsKey(key)).toList();
      if (missing.isNotEmpty) throw ArgumentError('Missing required fields: ${missing.join(', ')}');
    }
    if (data is BarcodeModel) return data;
    if (data is Map<String, dynamic>) {
      return BarcodeModel(
        code: data['code'] ?? '',
        title: data['title'] ?? '',
        subtitle: data['subtitle'] ?? '',
        extras: ExtraField.fromDynamic(data['extras']),
        scanned: (data['scanned'] as Map<String, dynamic>? ?? {}).map(
          (key, value) => MapEntry(key, (value as List).map((e) => e as int).toList()),
        ),
        timestamp: data['timestamp'] is int
          ? Timestamp.fromMillisecondsSinceEpoch(data['timestamp'])
          : data['timestamp'] ?? Timestamp.now(),
        lastActionByCategory: (data['lastActionByCategory'] as Map<String, dynamic>? ?? {})
            .map((key, value) => MapEntry(key, value.toString())),
        lastScanAt: data['lastScanAt'] as Timestamp?,
        lastScanCategory: data['lastScanCategory']?.toString(),
        lastScanAction: data['lastScanAction']?.toString(),
      );
    }
    return BarcodeModel.empty();
  }

  factory BarcodeModel.empty() => BarcodeModel(
        code: '',
        title: '',
        subtitle: '',
        extras: [],
        scanned: {},
        timestamp: Timestamp.now(),
        lastActionByCategory: const {},
        lastScanAt: null,
        lastScanCategory: null,
        lastScanAction: null,
        isScanned: null,
      );

  BarcodeModel copyWith(Map<String, dynamic> data) {
    return BarcodeModel.from({...toMap(), ...data});
  }

  Map<String, dynamic> toMap() {
    return {
      'code': code,
      'title': title,
      'subtitle': subtitle,
      'extras': extras.map((field) => field.toMap()).toList(),
      'scanned': scanned,
      'timestamp': timestamp,
      'lastActionByCategory': lastActionByCategory,
      'lastScanAt': lastScanAt,
      'lastScanCategory': lastScanCategory,
      'lastScanAction': lastScanAction,
    };
  }

  Map<String, dynamic> toJson() => {...toMap(), 'timestamp': timestamp.toDate().toIso8601String()};

  bool query(String searchTerm) {
    return code.toLowerCase().contains(searchTerm) ||
           title.toLowerCase().contains(searchTerm) ||
           subtitle.toLowerCase().contains(searchTerm) ||
           extras.map((f) => f.value).any((v) => v.toString().toLowerCase().contains(searchTerm)) ||
           timestamp.toDate().toString().contains(searchTerm);
  }

  bool matchesFilter(String field, String operator, dynamic value) {
    String fieldValue = '';
    switch (field) {
      case 'code': fieldValue = code;
      case 'title': fieldValue = title;
      case 'subtitle': fieldValue = subtitle;
      default: fieldValue = extras.firstWhere((e) => e.key == field, orElse: () => ExtraField(key: '', value: '')).value;
    }
    
    switch (operator) {
      case 'contains': return fieldValue.toLowerCase().contains(value.toLowerCase());
      case 'equals': return fieldValue == value;
      case 'starts with': return fieldValue.toLowerCase().startsWith(value.toLowerCase());
      case 'ends with': return fieldValue.toLowerCase().endsWith(value.toLowerCase());
      case 'not contains': return !fieldValue.toLowerCase().contains(value.toLowerCase());
      case 'not equals': return fieldValue != value;
      case 'in': return (value as List).contains(fieldValue);
      default: return true;
    }
  }
}
