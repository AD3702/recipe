import 'dart:convert';

import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class SubscriptionPlanEntity extends BaseEntity {
  String? code; // PLUS / PRO / ULTRA
  String? name; // Plus / Pro / Ultra
  String? userType;
  int priceMonthly;
  int priceYearly;
  String? currency; // INR
  int rank; // 1/2/3

  SubscriptionPlanEntity({
    super.id,
    super.uuid,
    super.active,
    super.deleted,
    super.createdAt,
    super.updatedAt,
    this.code,
    this.name,
    this.priceMonthly = 0,
    this.priceYearly = 0,
    this.currency,
    this.rank = 0,
  });

  factory SubscriptionPlanEntity.fromJson(Map<String, dynamic> json) => SubscriptionPlanEntity(
    id: parseInt(json['id']),
    uuid: json['uuid'] ?? const Uuid().v8(),
    active: parseBool(json['active'], true),
    deleted: parseBool(json['deleted'], false),
    createdAt: parseDateTime(json['created_at'], DateTime.now()),
    updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
    code: json['code'],
    name: json['name'],
    priceMonthly: parseInt(json['price_monthly']),
    priceYearly: parseInt(json['price_yearly']),
    currency: json['currency'] ?? 'INR',
    rank: parseInt(json['rank']),
  );

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'deleted'.snakeToCamel: deleted,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    'code'.snakeToCamel: code,
    'name'.snakeToCamel: name,
    'price_monthly'.snakeToCamel: priceMonthly,
    'price_yearly'.snakeToCamel: priceYearly,
    'currency'.snakeToCamel: currency,
    'rank'.snakeToCamel: rank,
  };

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'uuid': uuid,
    'active': active,
    'user_type': userType,
    'deleted': deleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'code': code,
    'name': name,
    'price_monthly': priceMonthly,
    'price_yearly': priceYearly,
    'currency': currency,
    'rank': rank,
  };
}