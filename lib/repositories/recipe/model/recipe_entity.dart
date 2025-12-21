import 'dart:convert';

import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

RecipeEntity userEntityFromJson(String str) => RecipeEntity.fromJson(json.decode(str));

String userEntityToJson(RecipeEntity data) => json.encode(data.toJson);

class RecipeEntity extends BaseEntity {
  int? categoryId;
  int? userId;
  String? name;
  double? serving;
  int? preparationTime;
  int? cookTime;
  List<String>? ingredients;
  List<String>? steps;
  String? note;
  String? nutritionInfo;

  RecipeEntity({
    super.id,
    super.uuid,
    super.active,
    super.deleted,
    super.createdAt,
    super.updatedAt,
    this.name,
    this.serving,
    this.cookTime,
    this.preparationTime,
    this.userId,
    this.categoryId,
    this.ingredients,
    this.note,
    this.nutritionInfo,
    this.steps,
  });

  factory RecipeEntity.fromJson(Map<String, dynamic> json) => RecipeEntity(
    id: parseInt(json['id']),
    uuid: json['uuid'] ?? const Uuid().v8(),
    active: parseBool(json['active'], true),
    deleted: parseBool(json['deleted'], false),
    createdAt: parseDateTime(json['created_at'], DateTime.now()),
    updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
    categoryId: json["category_id"] == null ? null : int.parse(json["category_id"].toString()),
    userId: json["user_id"] == null ? null : int.parse(json["user_id"].toString()),
    name: json["name"],
    serving: json["serving"] == null ? null : double.parse(json["serving"].toString()),
    preparationTime: json["preparation_time"] == null ? null : int.parse(json["preparation_time"].toString()),
    cookTime: json["cook_time"] == null ? null : int.parse(json["cook_time"].toString()),
    ingredients: json["ingredients"] == null
        ? []
        : json["ingredients"] is List
        ? List<String>.from(json["ingredients"]!.map((x) => x))
        : List<String>.from(jsonDecode(json["ingredients"]!).map((x) => x)),
    steps: json["ingredients"] == null
        ? []
        : json["steps"] is List
        ? List<String>.from(json["steps"]!.map((x) => x))
        : List<String>.from(jsonDecode(json["steps"]!).map((x) => x)),
    note: json["note"],
    nutritionInfo: json["nutrition_info"],
  );

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    "category_id".snakeToCamel: categoryId,
    "user_id".snakeToCamel: userId,
    "name".snakeToCamel: name,
    "serving".snakeToCamel: serving,
    "preparation_time".snakeToCamel: preparationTime,
    "cook_time".snakeToCamel: cookTime,
    "ingredients".snakeToCamel: ingredients == null ? [] : jsonEncode(ingredients!),
    "steps".snakeToCamel: steps == null ? [] : jsonEncode(steps!),
    "note".snakeToCamel: note,
    "nutrition_info".snakeToCamel: nutritionInfo,
  };

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'uuid': uuid,
    'active': active,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    "category_id": categoryId,
    "user_id": userId,
    "name": name,
    "serving": serving,
    "preparation_time": preparationTime,
    "cook_time": cookTime,
    "ingredients".snakeToCamel: ingredients == null ? [] : jsonEncode(ingredients!),
    "steps".snakeToCamel: steps == null ? [] : jsonEncode(steps!),
    "note": note,
    "nutrition_info": nutritionInfo,
    'deleted': deleted,
  };
}
