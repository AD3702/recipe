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

UserEntity userEntityFromJson(String str) => UserEntity.fromJson(json.decode(str));

String userEntityToJson(UserEntity data) => json.encode(data.toJson);

class UserEntity extends BaseEntity {
  String? name;
  String? contact;
  String? email;
  String? userName;
  String? password;
  UserType? userType;
  bool isContactVerified;
  bool isEmailVerified;
  bool isAdminApproved;
  bool isRejected;
  int liked;
  int bookmark;
  int views;
  int followers;
  int recipes;

  UserEntity({
    super.id,
    super.uuid,
    super.active,
    super.deleted,
    super.createdAt,
    super.updatedAt,
    this.name,
    this.contact,
    this.email,
    this.userName,
    this.password,
    this.liked = 0,
    this.bookmark = 0,
    this.views = 0,
    this.followers = 0,
    this.recipes = 0,
    this.userType = UserType.USER,
    this.isContactVerified = false,
    this.isEmailVerified = false,
    this.isAdminApproved = false,
    this.isRejected = false,
  });

  factory UserEntity.fromJson(Map<String, dynamic> json) {
    return UserEntity(
      id: parseInt(json['id']),
      recipes: parseInt(json['recipes']),
      liked: parseInt(json['liked']),
      bookmark: parseInt(json['bookmark']),
      views: parseInt(json['views']),
      followers: parseInt(json['followers']),
      uuid: json['uuid'] ?? const Uuid().v8(),
      active: parseBool(json['active'], true),
      deleted: parseBool(json['deleted'], false),
      createdAt: parseDateTime(json['created_at'], DateTime.now()),
      updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
      userType: (json['user_type']?.toString() ?? '').userTypeFromString ?? UserType.USER,
      name: json['name'],
      contact: json['contact'],
      email: json['email'],
      userName: json['user_name'],
      password: json['password'],
      isContactVerified: parseBool(json['is_contact_verified']),
      isEmailVerified: parseBool(json['is_email_verified']),
      isAdminApproved: parseBool(json['is_admin_approved']),
      isRejected: parseBool(json['is_rejected']),
    );
  }

  Map<String, dynamic> get toTableJson => {
    'id': id,
    'recipes': recipes,
    'liked': liked,
    'bookmark': bookmark,
    'views': views,
    'followers': followers,
    'uuid': uuid,
    'active': active,
    'deleted': deleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'user_type': userType?.name,
    'name': name,
    'user_name': userName,
    'contact': contact,
    'email': email,
    'password': password,
    'is_contact_verified': isContactVerified,
    'is_email_verified': isEmailVerified,
    'is_admin_approved': isAdminApproved,
    'is_rejected': isRejected,
  };

  Map<String, dynamic> get toJson => {
    'id'.snakeToCamel: id,
    'recipes'.snakeToCamel: recipes,
    'liked'.snakeToCamel: liked,
    'bookmark'.snakeToCamel: bookmark,
    'views'.snakeToCamel: views,
    'followers'.snakeToCamel: followers,
    'uuid'.snakeToCamel: uuid,
    'active'.snakeToCamel: active,
    'created_at'.snakeToCamel: createdAt.toIso8601String(),
    'updated_at'.snakeToCamel: updatedAt.toIso8601String(),
    'user_type'.snakeToCamel: userType?.name,
    'name'.snakeToCamel: name,
    'contact'.snakeToCamel: contact,
    'email'.snakeToCamel: email,
    'user_name'.snakeToCamel: userName,
    'is_contact_verified'.snakeToCamel: isContactVerified,
    'is_email_verified'.snakeToCamel: isEmailVerified,
    'is_admin_approved'.snakeToCamel: isAdminApproved,
    'is_rejected'.snakeToCamel: isRejected,
  };
}

enum UserType { SUPER_ADMIN, ADMIN, COOK, USER }

extension UserTypeExtension on String {
  UserType? get userTypeFromString {
    final normalized = trim().toUpperCase();
    return UserType.values.firstWhere((element) => element.name.toUpperCase() == normalized, orElse: () => UserType.USER);
  }
}
