import 'dart:convert';

import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class MonthlyRecipeMetricEntity extends BaseEntity {
  String? monthKey; // 2026-01
  int? recipeId;
  int? cookUserId;

  int? views;
  int? likes;
  int? bookmarks;
  int? purchases;
  double? score; // optional

  MonthlyRecipeMetricEntity({
    super.id,
    super.uuid,
    super.active,
    super.deleted,
    super.createdAt,
    super.updatedAt,
    this.monthKey,
    this.recipeId,
    this.cookUserId,
    this.views,
    this.likes,
    this.bookmarks,
    this.purchases,
    this.score,
  });

  factory MonthlyRecipeMetricEntity.fromJson(Map<String, dynamic> json) => MonthlyRecipeMetricEntity(
    id: parseInt(json['id']),
    uuid: json['uuid'] ?? const Uuid().v8(),
    active: parseBool(json['active'], true),
    deleted: parseBool(json['deleted'], false),
    createdAt: parseDateTime(json['created_at'], DateTime.now()),
    updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
    monthKey: json['month_key'],
    recipeId: parseInt(json['recipe_id']),
    cookUserId: parseInt(json['cook_user_id']),
    views: parseInt(json['views']),
    likes: parseInt(json['likes']),
    bookmarks: parseInt(json['bookmarks']),
    purchases: parseInt(json['purchases']),
    score: parseDouble(json['score']),
  );

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'deleted'.snakeToCamel: deleted,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    'month_key'.snakeToCamel: monthKey,
    'recipe_id'.snakeToCamel: recipeId,
    'cook_user_id'.snakeToCamel: cookUserId,
    'views'.snakeToCamel: views,
    'likes'.snakeToCamel: likes,
    'bookmarks'.snakeToCamel: bookmarks,
    'purchases'.snakeToCamel: purchases,
    'score'.snakeToCamel: score,
  };

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'uuid': uuid,
    'active': active,
    'deleted': deleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'month_key': monthKey,
    'recipe_id': recipeId,
    'cook_user_id': cookUserId,
    'views': views,
    'likes': likes,
    'bookmarks': bookmarks,
    'purchases': purchases,
    'score': score,
  };
}