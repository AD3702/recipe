import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:recipe/controller/mail_controller.dart';
import 'package:recipe/repositories/base/model/pagination_entity.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/user/model/user_entity.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:recipe/utils/list_extenstion.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

class UserController {
  late Connection connection;

  UserController._() {
    connection = BaseRepository.baseRepository.connection;
  }

  static UserController user = UserController._();
  final keys = UserEntity().toTableJson.keys.toList();

  ///CREATE SUPER ADMIN
  ///
  ///
  ///
  Future<void> createSuperAdmin() async {
    UserEntity? superAdmin = (await getUserFromUserType(UserType.SUPER_ADMIN)).firstOrNull;
    if (superAdmin == null) {
      String password = DBFunctions.generateRandomPassword(length: 16);
      superAdmin = UserEntity(
        name: AppConfig.superAdminName,
        email: AppConfig.superAdminEmail,
        contact: AppConfig.superAdminContact,
        userType: UserType.SUPER_ADMIN,
        isContactVerified: true,
        isEmailVerified: true,
        isAdminApproved: true,
        password: password.encryptPassword,
      );
      createNewUser(superAdmin);
      await MailController.mail.sendUserCreationSuccessfulEmail([AppConfig.superAdminEmail, AppConfig.personalEmail], AppConfig.superAdminName, password);
    }
  }

  ///GET USER LIST
  ///
  ///
  ///
  Future<(List<UserEntity>, PaginationEntity)> getUserList(Map<String, dynamic> requestBody) async {
    int? pageSize = int.tryParse(requestBody['page_size'].toString());
    int? pageNumber = int.tryParse(requestBody['page_number'].toString());
    final conditionData = DBFunctions.buildConditions(
      requestBody,
      searchKeys: ['name', 'email', 'contact'],
      limit: pageSize,
      offset: (pageNumber != null && pageSize != null) ? (pageNumber - 1) * pageSize : null,
    );

    final conditions = conditionData['conditions'] as List<String>;
    final suffix = conditionData['suffix'] as String;
    final params = conditionData['params'] as List<dynamic>;
    final suffixParams = conditionData['suffixParams'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.userDetails} WHERE ${conditions.join(' AND ')} $suffix';
    final countQuery = 'SELECT COUNT(*) FROM ${AppConfig.userDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params + suffixParams);
    final countRes = await connection.execute(Sql.named(countQuery), parameters: params);
    int totalCount = countRes.first.first as int;
    PaginationEntity paginationEntity = PaginationEntity(totalCount: totalCount, pageSize: pageSize ?? totalCount, pageNumber: pageNumber ?? 1);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    List<UserEntity> userList = [];
    for (var user in resList) {
      userList.add(UserEntity.fromJson(user));
    }
    return (userList, paginationEntity);
  }

  Future<Response> getUserListResponse(Map<String, dynamic> requestBody) async {
    var userList = await getUserList(requestBody);
    Map<String, dynamic> response = {'status': 200, 'message': 'User list found successfully'};
    response['data'] = userList.$1.map((e) => e.toJson).toList();
    response['pagination'] = userList.$2.toJson;
    return Response(200, body: jsonEncode(response));
  }

  ///GET USER DETAILS
  ///
  ///
  ///
  Future<Response> getUserFromUuidResponse(String uuid) async {
    var userResponse = await getUserFromUuid(uuid);

    if (userResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'User not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      Map<String, dynamic> response = {'status': 200, 'message': 'User found', 'data': userResponse.toJson};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<UserEntity?> getUserFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.userDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return UserEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<UserEntity?> getUserFromEmail(String email) async {
    final conditionData = DBFunctions.buildConditions({'email': email});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.userDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return UserEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<UserEntity?> getUserFromContact(String contact) async {
    final conditionData = DBFunctions.buildConditions({'contact': contact});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.userDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return UserEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<List<UserEntity>> getUserFromUserType(UserType userType) async {
    final conditionData = DBFunctions.buildConditions({'user_type': userType.name});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.userDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    List<UserEntity> userList = [];
    for (var user in resList) {
      userList.add(UserEntity.fromJson(user));
    }
    return userList;
  }

  ///ADD USER
  ///
  ///
  Future<Response> addUser(String request) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    List<String> requiredParams = ['name', 'email', 'contact', 'user_type'];
    List<String> requestParams = requestData.keys.toList();
    var res = DBFunctions.checkParamValidRequest(requestParams, requiredParams);
    if (res != null) {
      response['message'] = res;
      return Response.badRequest(body: jsonEncode(response));
    }
    UserEntity? userEntity = UserEntity.fromJson(requestData);
    String password = userEntity.password ?? DBFunctions.generateRandomPassword();
    userEntity.password = password.encryptPassword;
    userEntity.isAdminApproved = true;
    if (userEntity.userType == null) {
      response['message'] = 'Usertype must be in ${UserType.values.map((e) => e.name).toList()}';
      return Response.badRequest(body: jsonEncode(response));
    }
    UserEntity? userWithEmail = await getUserFromEmail(userEntity.email ?? '');
    if (userWithEmail != null) {
      response['message'] = 'User with email already exists';
      return Response.badRequest(body: jsonEncode(response));
    }
    UserEntity? userWithContact = await getUserFromContact(userEntity.contact ?? '');
    if (userWithContact != null) {
      response['message'] = 'User with contact already exists';
      return Response.badRequest(body: jsonEncode(response));
    }
    userEntity = await createNewUser(userEntity);
    response['status'] = 200;
    response['message'] = 'User created successfully';
    if (userEntity != null) {
      // MailController.mail.sendUserCreationSuccessfulEmail([userEntity.email!], userEntity.name!, password);
    }
    return Response(201, body: jsonEncode(response));
  }

  ///CREATE USER
  ///
  ///
  ///
  Future<UserEntity?> createNewUser(UserEntity user) async {
    var insertQuery = DBFunctions.generateInsertQueryFromClass(AppConfig.userDetails, user.toTableJson);
    final query = insertQuery['query'] as String;
    final params = insertQuery['params'] as List<dynamic>;
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return UserEntity.fromJson(resList.first);
    }
    return null;
  }

  ///DELETE USER
  ///
  ///
  ///
  Future<Response> deleteUserFromUuidResponse(String uuid) async {
    print(uuid);
    var userResponse = await getUserFromUuid(uuid);
    if (userResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'User not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      await deleteUserFromUuid(uuid);
      Map<String, dynamic> response = {'status': 200, 'message': 'User deleted successfully'};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<List<dynamic>> deleteUserFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.userDetails} SET deleted = true, active = false WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    return DBFunctions.mapFromResultRow(res, keys);
  }

  ///DEACTIVATE USER
  ///
  ///
  ///
  Future<Response> deactivateUserFromUuidResponse(String uuid, bool active) async {
    print(uuid);
    var userResponse = await getUserFromUuid(uuid);
    if (userResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'User not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      if (userResponse.active == active) {
        Map<String, dynamic> response = {'status': 404, 'message': 'User already ${active ? 'Active' : 'De-Active'}'};
        return Response(200, body: jsonEncode(response));
      }
      await deactivateUserFromUuid(uuid, active);
      Map<String, dynamic> response = {'status': 200, 'message': 'User status changed successfully'};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<List<dynamic>> deactivateUserFromUuid(String uuid, bool active) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.userDetails} SET active = $active WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    return DBFunctions.mapFromResultRow(res, keys);
  }
}
