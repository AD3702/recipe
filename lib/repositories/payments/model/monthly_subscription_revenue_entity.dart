import 'dart:convert';

import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class MonthlySubscriptionRevenueEntity extends BaseEntity {
  String? monthKey; // 2026-01
  String? planCode; // nullable if total
  int? grossRevenue;
  int? platformRevenue;
  int? cookPoolRevenue;
  String? currency;

  MonthlySubscriptionRevenueEntity({
    super.id,
    super.uuid,
    super.active,
    super.deleted,
    super.createdAt,
    super.updatedAt,
    this.monthKey,
    this.planCode,
    this.grossRevenue,
    this.platformRevenue,
    this.cookPoolRevenue,
    this.currency,
  });

  factory MonthlySubscriptionRevenueEntity.fromJson(Map<String, dynamic> json) => MonthlySubscriptionRevenueEntity(
    id: parseInt(json['id']),
    uuid: json['uuid'] ?? const Uuid().v8(),
    active: parseBool(json['active'], true),
    deleted: parseBool(json['deleted'], false),
    createdAt: parseDateTime(json['created_at'], DateTime.now()),
    updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
    monthKey: json['month_key'],
    planCode: json['plan_code'],
    grossRevenue: parseInt(json['gross_revenue']),
    platformRevenue: parseInt(json['platform_revenue']),
    cookPoolRevenue: parseInt(json['cook_pool_revenue']),
    currency: json['currency'] ?? 'INR',
  );

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'deleted'.snakeToCamel: deleted,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    'month_key'.snakeToCamel: monthKey,
    'plan_code'.snakeToCamel: planCode,
    'gross_revenue'.snakeToCamel: grossRevenue,
    'platform_revenue'.snakeToCamel: platformRevenue,
    'cook_pool_revenue'.snakeToCamel: cookPoolRevenue,
    'currency'.snakeToCamel: currency,
  };

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'uuid': uuid,
    'active': active,
    'deleted': deleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'month_key': monthKey,
    'plan_code': planCode,
    'gross_revenue': grossRevenue,
    'platform_revenue': platformRevenue,
    'cook_pool_revenue': cookPoolRevenue,
    'currency': currency,
  };
}