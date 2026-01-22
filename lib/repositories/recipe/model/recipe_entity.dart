import 'dart:convert';

import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/repositories/category/model/category_entity.dart';
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
  List<String>? categoryUuids;
  List<String>? categoryName;
  String? userUuid;
  String? userName;
  String? name;
  String? accessTier;
  String? currency;
  bool? isPurchased;
  int? price;
  double? serving;
  int? preparationTime;
  int? cookTime;
  List<String>? ingredients;
  List<String>? steps;
  String? note;
  String? nutritionInfo;
  bool? isBookmarked;
  int? views;
  int? likedCount;
  int? bookmarkedCount;
  bool? isLiked;
  List<String>? recipeImageUrls;

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
    this.userUuid,
    this.categoryUuids,
    this.categoryName,
    this.ingredients,
    this.note,
    this.nutritionInfo,
    this.recipeImageUrls,
    this.views,
    this.isBookmarked,
    this.likedCount,
    this.bookmarkedCount,
    this.isLiked,
    this.steps,
    this.userName,
    this.currency,
    this.accessTier,
    this.price,
  });

  factory RecipeEntity.fromJson(Map<String, dynamic> json) => RecipeEntity(
    id: parseInt(json['id']),
    views: parseInt(json['views']),
    likedCount: parseInt(json['likedCount']),
    bookmarkedCount: parseInt(json['bookmarkedCount']),
    price: parseInt(json['price']),
    currency: json['currency'],
    accessTier: json['accessTier'],
    uuid: json['uuid'] ?? const Uuid().v8(),
    active: parseBool(json['active'], true),
    deleted: parseBool(json['deleted'], false),
    isBookmarked: parseBool(json['is_bookmarked'], false),
    isLiked: parseBool(json['is_liked'], false),
    createdAt: parseDateTime(json['created_at'], DateTime.now()),
    updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
    categoryUuids: json["category_uuid"] == null
        ? []
        : json["category_uuid"] is List
        ? List<String>.from(json["category_uuid"].map((x) => x))
        : List<String>.from(jsonDecode(json["category_uuid"]).map((x) => x)),
    userUuid: json["user_uuid"],
    name: json["name"],
    serving: json["serving"] == null ? null : double.parse(json["serving"].toString()),
    preparationTime: json["preparation_time"] == null ? null : int.parse(json["preparation_time"].toString()),
    cookTime: json["cook_time"] == null ? null : int.parse(json["cook_time"].toString()),
    ingredients: json["ingredients"] == null
        ? []
        : json["ingredients"] is List
        ? List<String>.from(json["ingredients"]!.map((x) => x))
        : List<String>.from(jsonDecode(json["ingredients"]!).map((x) => x)),
    steps: json["steps"] == null
        ? []
        : json["steps"] is List
        ? List<String>.from(json["steps"]!.map((x) => x))
        : List<String>.from(jsonDecode(json["steps"]!).map((x) => x)),
    note: json["note"],
    nutritionInfo: json["nutrition_info"],
    recipeImageUrls: json["recipe_image_urls"] == null
        ? []
        : json["recipe_image_urls"] is List
        ? List<String>.from(json["recipe_image_urls"]!.map((x) => x))
        : List<String>.from(jsonDecode(json["recipe_image_urls"]!).map((x) => x)),
  );

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'views'.snakeToCamel: views,
    'is_purchased'.snakeToCamel: isPurchased,
    'price'.snakeToCamel: price,
    'currency'.snakeToCamel: currency,
    'accessTier'.snakeToCamel: accessTier,
    'liked_count'.snakeToCamel: likedCount,
    'bookmarked_count'.snakeToCamel: bookmarkedCount,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'is_bookmarked'.snakeToCamel: isBookmarked,
    'is_liked'.snakeToCamel: isLiked,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    "category_uuid".snakeToCamel: categoryUuids == null ? [] : jsonEncode(categoryUuids!),
    "user_uuid".snakeToCamel: userUuid,
    "name".snakeToCamel: name,
    "serving".snakeToCamel: serving,
    "preparation_time".snakeToCamel: preparationTime,
    "cook_time".snakeToCamel: cookTime,
    "ingredients".snakeToCamel: ingredients == null ? [] : jsonEncode(ingredients!),
    "steps".snakeToCamel: steps == null ? [] : jsonEncode(steps!),
    "category_name".snakeToCamel: steps == null ? [] : jsonEncode(categoryName!),
    "user_name".snakeToCamel: userName,
    "note".snakeToCamel: note,
    "nutrition_info".snakeToCamel: nutritionInfo,
    "recipe_image_urls".snakeToCamel: recipeImageUrls == null ? [] : jsonEncode(recipeImageUrls!),
  };

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'views': views,
    'liked_count': likedCount,
    'bookmarked_count': bookmarkedCount,
    'uuid': uuid,
    'active': active,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    "category_uuid": categoryUuids == null ? [] : jsonEncode(categoryUuids!),
    "user_uuid": userUuid,
    "name": name,
    "serving": serving,
    "preparation_time": preparationTime,
    "cook_time": cookTime,
    "ingredients".snakeToCamel: ingredients == null ? [] : jsonEncode(ingredients!),
    "steps".snakeToCamel: steps == null ? [] : jsonEncode(steps!),
    "note": note,
    "nutrition_info": nutritionInfo,
    "recipe_image_urls": recipeImageUrls == null ? [] : jsonEncode(recipeImageUrls!),
    'deleted': deleted,
  };
}
