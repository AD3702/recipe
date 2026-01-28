import 'dart:convert';

import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class RecipePricingEntity extends BaseEntity {
  int recipeId;
  String accessTier; // FREE/PLUS/PRO/ULTRA/PAID
  int price; // required when PAID
  String currency; // INR

  RecipePricingEntity({
    super.id,
    super.uuid,
    super.active,
    super.deleted,
    super.createdAt,
    super.updatedAt,
    this.recipeId = 0,
    this.accessTier = '',
    this.price = 0,
    this.currency = '',
  });

  factory RecipePricingEntity.fromJson(Map<String, dynamic> json) => RecipePricingEntity(
    id: parseInt(json['id']),
    uuid: json['uuid'] ?? const Uuid().v8(),
    active: parseBool(json['active'], true),
    deleted: parseBool(json['deleted'], false),
    createdAt: parseDateTime(json['created_at'], DateTime.now()),
    updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
    recipeId: parseInt(json['recipe_id']),
    accessTier: json['access_tier'] ?? 'FREE',
    price: parseInt(json['price']),
    currency: json['currency'] ?? 'INR',
  );

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'deleted'.snakeToCamel: deleted,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    'recipe_id'.snakeToCamel: recipeId,
    'access_tier'.snakeToCamel: accessTier,
    'price'.snakeToCamel: price,
    'currency'.snakeToCamel: currency,
  };

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'uuid': uuid,
    'active': active,
    'deleted': deleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'recipe_id': recipeId,
    'access_tier': accessTier,
    'price': price,
    'currency': currency,
  };
}