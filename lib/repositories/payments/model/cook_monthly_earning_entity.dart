import 'dart:convert';

import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class CookMonthlyEarningEntity extends BaseEntity {
  String monthKey; // 2026-01
  int cookUserId;
  String source; // SUB_POOL / DIRECT_SALE
  int amount;
  String currency;
  String status; // PENDING / PAID

  CookMonthlyEarningEntity({
    super.id,
    super.uuid,
    super.active,
    super.deleted,
    super.createdAt,
    super.updatedAt,
    this.monthKey = '',
    this.cookUserId = 0,
    this.source = '',
    this.amount = 0,
    this.currency = '',
    this.status = '',
  });

  factory CookMonthlyEarningEntity.fromJson(Map<String, dynamic> json) => CookMonthlyEarningEntity(
    id: parseInt(json['id']),
    uuid: json['uuid'] ?? const Uuid().v8(),
    active: parseBool(json['active'], true),
    deleted: parseBool(json['deleted'], false),
    createdAt: parseDateTime(json['created_at'], DateTime.now()),
    updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
    monthKey: json['month_key'],
    cookUserId: parseInt(json['cook_user_id']),
    source: json['source'] ?? 'SUB_POOL',
    amount: parseInt(json['amount']),
    currency: json['currency'] ?? 'INR',
    status: json['status'] ?? 'PENDING',
  );

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'deleted'.snakeToCamel: deleted,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    'month_key'.snakeToCamel: monthKey,
    'cook_user_id'.snakeToCamel: cookUserId,
    'source'.snakeToCamel: source,
    'amount'.snakeToCamel: amount,
    'currency'.snakeToCamel: currency,
    'status'.snakeToCamel: status,
  };

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'uuid': uuid,
    'active': active,
    'deleted': deleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'month_key': monthKey,
    'cook_user_id': cookUserId,
    'source': source,
    'amount': amount,
    'currency': currency,
    'status': status,
  };
}