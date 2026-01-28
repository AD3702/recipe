import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class UserFollowersTable {
  int id;
  int userId;
  int userFollowingId;
  DateTime createdAt;
  DateTime updatedAt;

  UserFollowersTable({this.id = 0, this.userFollowingId = 0, this.userId = 0, DateTime? createdAt, DateTime? updatedAt})
    : createdAt = createdAt ?? DateTime.now(),
      updatedAt = updatedAt ?? DateTime.now();

  factory UserFollowersTable.fromJson(Map<String, dynamic> json) {
    return UserFollowersTable(
      id: parseInt(json['id']),
      createdAt: parseDateTime(json['created_at'], DateTime.now()),
      updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
      userId: json['user_id'],
      userFollowingId: json['user_following_id'],
    );
  }

  Map<String, dynamic> get toJson {
    return {
      'id'.snakeToCamel: id,
      'created_at'.snakeToCamel: createdAt.toIso8601String(),
      'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
      'user_id'.snakeToCamel: userId,
      'user_following_id'.snakeToCamel: userFollowingId,
    };
  }

  Map<String, dynamic> get toTableJson {
    return {'id': id, 'created_at': createdAt.toIso8601String(), 'updated_at': updatedAt.toIso8601String(), 'user_id': userId, 'user_following_id': userFollowingId};
  }
}
