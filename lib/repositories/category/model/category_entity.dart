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

CategoryEntity userEntityFromJson(String str) => CategoryEntity.fromJson(json.decode(str));

String userEntityToJson(CategoryEntity data) => json.encode(data.toJson);

class CategoryEntity extends BaseEntity {
  String? name;

  CategoryEntity({super.id, super.uuid, super.active, super.deleted, super.createdAt, super.updatedAt, this.name});

  factory CategoryEntity.fromJson(Map<String, dynamic> json) {
    return CategoryEntity(
      id: parseInt(json['id']),
      uuid: json['uuid'] ?? const Uuid().v8(),
      active: parseBool(json['active'], true),
      deleted: parseBool(json['deleted'], false),
      createdAt: parseDateTime(json['created_at'], DateTime.now()),
      updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
      name: json['name'],
    );
  }

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'uuid': uuid,
    'active': active,
    'deleted': deleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'name': name,
  };

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    'name'.snakeToCamel: name,
  };
}
