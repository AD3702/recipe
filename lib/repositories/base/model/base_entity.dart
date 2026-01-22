import 'package:uuid/uuid.dart';

class BaseEntity {
  int id;
  String uuid;
  bool active;
  bool deleted;
  DateTime createdAt;
  DateTime updatedAt;

  BaseEntity({this.id = 0, String? uuid, this.active = true, this.deleted = false, DateTime? createdAt, DateTime? updatedAt})
    : uuid = uuid ?? const Uuid().v8(),
      createdAt = createdAt ?? DateTime.now(),
      updatedAt = updatedAt ?? DateTime.now();
}

int parseInt(dynamic value, [int defaultValue = 0]) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? defaultValue;
  return defaultValue;
}

double parseDouble(dynamic value, [double defaultValue = 0]) {
  if (value is double) return value;
  if (value is String) return double.tryParse(value) ?? defaultValue;
  return defaultValue;
}

bool parseBool(dynamic value, [bool defaultValue = false]) {
  if (value is bool) return value;
  if (value is String) {
    final v = value.toLowerCase().trim();
    if (v == 'true' || v == '1') return true;
    if (v == 'false' || v == '0') return false;
  }
  if (value is num) return value != 0;
  return defaultValue;
}

DateTime parseDateTime(dynamic value, [DateTime? defaultValue]) {
  if (value is DateTime) return value;
  if (value is String) {
    try {
      return DateTime.parse(value);
    } catch (_) {
      return defaultValue ?? DateTime.now();
    }
  }
  return defaultValue ?? DateTime.now();
}