import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class RecipeViewsList {
  int id;
  int userId;
  int recipeId;
  int times;
  DateTime createdAt;
  DateTime updatedAt;

  RecipeViewsList({this.id = 0, this.times = 0, this.userId = 0, this.recipeId = 0, DateTime? createdAt, DateTime? updatedAt})
    : createdAt = createdAt ?? DateTime.now(),
      updatedAt = updatedAt ?? DateTime.now();

  factory RecipeViewsList.fromJson(Map<String, dynamic> json) {
    return RecipeViewsList(
      id: parseInt(json['id']),
      times: parseInt(json['times']),
      createdAt: parseDateTime(json['created_at'], DateTime.now()),
      updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
      userId: json['user_id'],
      recipeId: json['recipe_id'],
    );
  }

  Map<String, dynamic> get toJson {
    return {
      'id'.snakeToCamel: id,
      'times'.snakeToCamel: times,
      'created_at'.snakeToCamel: createdAt.toIso8601String(),
      'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
      'user_id'.snakeToCamel: userId,
      'recipe_id'.snakeToCamel: recipeId,
    };
  }

  Map<String, dynamic> get toTableJson {
    return {'id': id, 'times': times, 'created_at': createdAt.toIso8601String(), 'updated_at': updatedAt.toIso8601String(), 'user_id': userId, 'recipe_id': recipeId};
  }
}
