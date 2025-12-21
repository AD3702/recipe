import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class GenerateOtp extends BaseEntity {
  int userId;
  String otp;

  GenerateOtp({super.id, super.uuid, super.active, super.deleted, super.createdAt, super.updatedAt, this.userId = 0, this.otp = '123456'});

  factory GenerateOtp.fromJson(Map<String, dynamic> json) {
    return GenerateOtp(
      id: parseInt(json['id']),
      uuid: json['uuid'] ?? const Uuid().v8(),
      active: parseBool(json['active'], true),
      deleted: parseBool(json['deleted'], false),
      createdAt: parseDateTime(json['created_at'], DateTime.now()),
      updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
      userId: parseInt('user_id'),
      otp: json['otp'],
    );
  }

  Map<String, dynamic> get toJson {
    return {
      'id'.snakeToCamel: id,
      'uuid'.snakeToCamel: uuid,
      'active'.snakeToCamel: active,
      'created_at'.snakeToCamel: createdAt.toIso8601String(),
      'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
      'user_id'.snakeToCamel: userId,
      'otp'.snakeToCamel: otp,
    };
  }

  Map<String, dynamic> get toTableJson {
    return {'id': id, 'uuid': uuid, 'active': active, 'deleted': deleted, 'created_at': createdAt.toIso8601String(), 'updated_at': updatedAt.toIso8601String(), 'user_id': userId, 'otp': otp};
  }
}
