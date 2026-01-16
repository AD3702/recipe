import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:uuid/uuid.dart';

class UserDocumentsModel extends BaseEntity {
  String userUuid;
  String filePath;
  String documentType;

  UserDocumentsModel({super.id, super.uuid, super.active, super.deleted, super.createdAt, super.updatedAt, this.userUuid = '', this.filePath = '', this.documentType = ''});

  factory UserDocumentsModel.fromJson(Map<String, dynamic> json) {
    return UserDocumentsModel(
      id: parseInt(json['id']),
      uuid: json['uuid'] ?? const Uuid().v8(),
      active: parseBool(json['active'], true),
      deleted: parseBool(json['deleted'], false),
      createdAt: parseDateTime(json['created_at'], DateTime.now()),
      updatedAt: parseDateTime(json['updated_at'], DateTime.now()),
      userUuid: json['user_uuid'],
      filePath: json['file_path'],
      documentType: json['document_type'],
    );
  }

  Map<String, dynamic> get toJson {
    return {
      'uuid'.snakeToCamel: uuid,
      'file_path'.snakeToCamel: filePath,
      'user_uuid'.snakeToCamel: userUuid,
      'document_type'.snakeToCamel: documentType,
    };
  }

  Map<String, dynamic> get toTableJson {
    return {
      'id': id,
      'uuid': uuid,
      'active': active,
      'deleted': deleted,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'user_uuid': userUuid,
      'file_path': filePath,
      'document_type': documentType,
    };
  }
}
