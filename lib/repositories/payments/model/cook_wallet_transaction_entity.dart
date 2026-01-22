import 'dart:convert';

import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class CookWalletTransactionEntity extends BaseEntity {
  int? cookUserId;
  String? monthKey; // nullable
  String? type; // CREDIT/DEBIT
  String? source; // SUB_POOL/RECIPE_SALE/REFUND/ADJUSTMENT
  String? refTable;
  int? refId;
  int? amount;
  String? currency;
  String? note;

  CookWalletTransactionEntity({
    super.id,
    super.uuid,
    super.active,
    super.deleted,
    super.createdAt,
    super.updatedAt,
    this.cookUserId,
    this.monthKey,
    this.type,
    this.source,
    this.refTable,
    this.refId,
    this.amount,
    this.currency,
    this.note,
  });

  factory CookWalletTransactionEntity.fromJson(Map<String, dynamic> json) => CookWalletTransactionEntity(
    id: parseInt(json['id']),
    uuid: json['uuid'] ?? const Uuid().v8(),
    active: parseBool(json['active'], true),
    deleted: parseBool(json['deleted'], false),
    createdAt: parseDateTime(json['created_at'], DateTime.now()),
    updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
    cookUserId: parseInt(json['cook_user_id']),
    monthKey: json['month_key'],
    type: json['type'] ?? 'CREDIT',
    source: json['source'],
    refTable: json['ref_table'],
    refId: parseInt(json['ref_id']),
    amount: parseInt(json['amount']),
    currency: json['currency'] ?? 'INR',
    note: json['note'],
  );

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'deleted'.snakeToCamel: deleted,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    'cook_user_id'.snakeToCamel: cookUserId,
    'month_key'.snakeToCamel: monthKey,
    'type'.snakeToCamel: type,
    'source'.snakeToCamel: source,
    'ref_table'.snakeToCamel: refTable,
    'ref_id'.snakeToCamel: refId,
    'amount'.snakeToCamel: amount,
    'currency'.snakeToCamel: currency,
    'note'.snakeToCamel: note,
  };

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'uuid': uuid,
    'active': active,
    'deleted': deleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'cook_user_id': cookUserId,
    'month_key': monthKey,
    'type': type,
    'source': source,
    'ref_table': refTable,
    'ref_id': refId,
    'amount': amount,
    'currency': currency,
    'note': note,
  };
}