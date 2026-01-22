import 'dart:convert';

import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class UserSubscriptionEntity extends BaseEntity {
  int? userId;
  int? recipeId;
  String? planCode; // PLUS/PRO/ULTRA
  DateTime? startAt;
  DateTime? endAt;
  String? status; // ACTIVE/EXPIRED/CANCELLED
  int? amountPaid;
  String? currency; // INR
  String? paymentProvider; // RAZORPAY/STRIPE
  String? providerSubscriptionId;
  String? providerPaymentId;

  UserSubscriptionEntity({
    super.id,
    super.uuid,
    super.active,
    super.deleted,
    super.createdAt,
    super.updatedAt,
    this.userId,
    this.recipeId,
    this.planCode,
    this.startAt,
    this.endAt,
    this.status,
    this.amountPaid,
    this.currency,
    this.paymentProvider,
    this.providerSubscriptionId,
    this.providerPaymentId,
  });

  factory UserSubscriptionEntity.fromJson(Map<String, dynamic> json) => UserSubscriptionEntity(
    id: parseInt(json['id']),
    uuid: json['uuid'] ?? const Uuid().v8(),
    active: parseBool(json['active'], true),
    deleted: parseBool(json['deleted'], false),
    createdAt: parseDateTime(json['created_at'], DateTime.now()),
    updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
    userId: parseInt(json['user_id']),
    recipeId: parseInt(json['recipe_id']),
    planCode: json['plan_code'],
    startAt: parseDateTime(json['start_at'], null),
    endAt: parseDateTime(json['end_at'], null),
    status: json['status'],
    amountPaid: parseInt(json['amount_paid']),
    currency: json['currency'] ?? 'INR',
    paymentProvider: json['payment_provider'],
    providerSubscriptionId: json['provider_subscription_id'],
    providerPaymentId: json['provider_payment_id'],
  );

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'recipe_id'.snakeToCamel: recipeId,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'deleted'.snakeToCamel: deleted,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    'user_id'.snakeToCamel: userId,
    'plan_code'.snakeToCamel: planCode,
    'start_at'.snakeToCamel: startAt?.toIso8601String(),
    'end_at'.snakeToCamel: endAt?.toIso8601String(),
    'status'.snakeToCamel: status,
    'amount_paid'.snakeToCamel: amountPaid,
    'currency'.snakeToCamel: currency,
    'payment_provider'.snakeToCamel: paymentProvider,
    'provider_subscription_id'.snakeToCamel: providerSubscriptionId,
    'provider_payment_id'.snakeToCamel: providerPaymentId,
  };

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'uuid': uuid,
    'active': active,
    'deleted': deleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'user_id': userId,
    'recipe_id': recipeId,
    'plan_code': planCode,
    'start_at': startAt?.toIso8601String(),
    'end_at': endAt?.toIso8601String(),
    'status': status,
    'amount_paid': amountPaid,
    'currency': currency,
    'payment_provider': paymentProvider,
    'provider_subscription_id': providerSubscriptionId,
    'provider_payment_id': providerPaymentId,
  };
}