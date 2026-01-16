import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class RecipeViewsList extends BaseEntity {
  String userUuid;
  String recipeUuid;
  int times;

  RecipeViewsList({super.id, super.uuid, super.active, super.deleted, super.createdAt, super.updatedAt, this.userUuid = '', this.recipeUuid = '', this.times = 0});

  factory RecipeViewsList.fromJson(Map<String, dynamic> json) {
    return RecipeViewsList(
      id: parseInt(json['id']),
      times: parseInt(json['times']),
      uuid: json['uuid'] ?? const Uuid().v8(),
      active: parseBool(json['active'], true),
      deleted: parseBool(json['deleted'], false),
      createdAt: parseDateTime(json['created_at'], DateTime.now()),
      updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
      userUuid: json['user_uuid'],
      recipeUuid: json['recipe_uuid'],
    );
  }

  Map<String, dynamic> get toJson {
    return {
      'id'.snakeToCamel: id,
      'times'.snakeToCamel: times,
      'uuid'.snakeToCamel: uuid,
      'active'.snakeToCamel: active,
      'created_at'.snakeToCamel: createdAt.toIso8601String(),
      'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
      'user_uuid'.snakeToCamel: userUuid,
      'recipe_uuid'.snakeToCamel: recipeUuid,
    };
  }

  Map<String, dynamic> get toTableJson {
    return {
      'id': id,
      'times': times,
      'uuid': uuid,
      'active': active,
      'deleted': deleted,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'user_uuid': userUuid,
      'recipe_uuid': recipeUuid,
    };
  }
}
