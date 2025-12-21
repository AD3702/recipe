import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:recipe/controller/mail_controller.dart';
import 'package:recipe/repositories/auth/model/generate_otp.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/user/model/user_entity.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:recipe/utils/list_extenstion.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

class AuthController {
  late Connection connection;

  AuthController._() {
    connection = BaseRepository.baseRepository.connection;
  }

  static AuthController auth = AuthController._();
  final keys = UserEntity().toTableJson.keys.toList();
  final otpKeys = GenerateOtp().toTableJson.keys.toList();

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

  Future<UserEntity?> getUserFromEmailAndUserType(String email, String userType) async {
    final conditionData = DBFunctions.buildConditions({'email': email, 'user_type': userType});
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

  ///LOGIN USER
  ///
  ///
  Future<Response> login(String request) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    UserEntity? userEntity;
    if (requestData['email'] != null) {
      userEntity = await getUserFromEmail(requestData['email']);
      if (userEntity == null) {
        response['message'] = 'User with email ${requestData['email']} does not exist.';
        return Response.badRequest(body: jsonEncode(response));
      }
    }
    String password = requestData['password'];
    if (userEntity?.password != password.encryptPassword) {
      response['message'] = 'The password you entered is incorrect.';
      return Response.badRequest(body: jsonEncode(response));
    }
    userEntity = await getUserFromEmail(requestData['email']);
    response['status'] = 200;
    response['message'] = 'Login successful.';
    response['data'] = userEntity?.toJson;
    response['data']['token'] = BaseRepository.baseRepository.generateJwtToken(userEntity?.email ?? '', userEntity?.userType ?? UserType.USER);
    return Response(200, body: jsonEncode(response));
  }

  ///UPDATE TOKEN
  ///
  ///
  Future<Response> updateToken(String token) async {
    UserEntity? userEntity;
    Map<String, dynamic> response = {'status': 400};
    var payloadJson = BaseRepository.baseRepository.verifyToken(token);
    if (payloadJson != null) {
      print(jsonDecode(payloadJson));
      String userName = jsonDecode(payloadJson)['userName'];
      String userType = jsonDecode(payloadJson)['userType'];
      userEntity = await getUserFromEmailAndUserType(userName.decryptBasic, userType.decryptBasic);
      response['data'] = BaseRepository.baseRepository.generateJwtToken(userEntity?.email ?? '', userEntity?.userType ?? UserType.USER);
      response['status'] = 200;
      return Response(200, body: jsonEncode(response));
    }
    return Response(400);
  }

  ///GENERATE OTP
  ///
  ///
  Future<Response> generateOtp(String request) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    UserEntity? userEntity;
    if (requestData['email'] != null) {
      userEntity = await getUserFromEmail(requestData['email']);
      if (userEntity == null) {
        response['message'] = 'User with email ${requestData['email']} does not exist.';
        return Response.badRequest(body: jsonEncode(response));
      }
    }
    if (requestData['contact'] != null) {
      userEntity = await getUserFromContact(requestData['contact']);
      if (userEntity == null) {
        response['message'] = 'User with contact ${requestData['contact']} does not exist.';
        return Response.badRequest(body: jsonEncode(response));
      }
    }
    // fetch any existing OTP
    final existingOtp = await getOldGeneratedOtp(userEntity!.id);
    await insertNewOtp(userEntity, generateOtp: existingOtp);
    response['status'] = 200;
    response['message'] = 'OTP generated successfully.';
    return Response(200, body: jsonEncode(response));
  }

  ///VERIFY OTP
  ///
  ///
  Future<(Response, UserEntity?)> verifyOtp(String request) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    bool isEmailUpdate = false;
    UserEntity? userEntity;
    if (requestData['email'] != null) {
      isEmailUpdate = true;
      userEntity = await getUserFromEmail(requestData['email']);
      if (userEntity == null) {
        response['message'] = 'User with email ${requestData['email']} does not exist.';
        return (Response.badRequest(body: jsonEncode(response)), null);
      }
    }
    if (requestData['contact'] != null) {
      userEntity = await getUserFromContact(requestData['contact']);
      if (userEntity == null) {
        response['message'] = 'User with contact ${requestData['contact']} does not exist.';
        return (Response.badRequest(body: jsonEncode(response)), null);
      }
    }
    final existingOtp = await getOldGeneratedOtp(userEntity!.id);
    if (existingOtp == null) {
      response['message'] = 'No OTP has been generated for this user.';
      return (Response.badRequest(body: jsonEncode(response)), null);
    }
    if (existingOtp.otp != requestData['otp']) {
      response['message'] = 'The OTP you entered is incorrect. Please try again.';
      return (Response.badRequest(body: jsonEncode(response)), null);
    }
    if (existingOtp.createdAt.difference(DateTime.now()).inSeconds.abs() > 60) {
      response['message'] = 'The OTP you entered is expired. Please generate again.';
      return (Response.badRequest(body: jsonEncode(response)), null);
    }
    await connection.execute(
      Sql.named('UPDATE ${AppConfig.userDetails} SET ${isEmailUpdate ? 'is_email_verified' : 'is_contact_verified'} = @${isEmailUpdate ? 'is_email_verified' : 'is_contact_verified'} WHERE id = @id'),
      parameters: {isEmailUpdate ? 'is_email_verified' : 'is_contact_verified': true, 'id': userEntity.id},
    );
    response['status'] = 200;
    response['message'] = 'OTP verified successfully.';
    await deleteOldGeneratedOtp(existingOtp.id);
    return (Response(200, body: jsonEncode(response)), userEntity);
  }

  Future<Response> resetPassword(String request) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    if (requestData['password'] == null) {
      response['message'] = 'Password is required';
      return Response.badRequest(body: jsonEncode(response));
    }
    var verifyResponse = await verifyOtp(request);
    if (verifyResponse.$1.statusCode != 200) {
      return verifyResponse.$1;
    }
    await connection.execute(
      Sql.named('UPDATE ${AppConfig.userDetails} SET password = @password WHERE id = @id'),
      parameters: {'password': requestData['password'].toString().encryptPassword, 'id': verifyResponse.$2?.id},
    );
    response['status'] = 200;
    response['message'] = 'Password reset successfully.';
    return Response(200, body: jsonEncode(response));
  }

  Future<GenerateOtp?> insertNewOtp(UserEntity userEntity, {GenerateOtp? generateOtp}) async {
    // Throttle window for reissuing OTP
    const throttle = Duration(seconds: 60);
    final now = DateTime.now();
    // If no previous OTP, create a new one
    if (generateOtp == null) {
      final otp = DBFunctions.generateRandomOtp();
      return await generateNewOtp(GenerateOtp(userId: userEntity.id, otp: otp));
    }
    // If previous OTP exists, check age
    final age = now.difference(generateOtp.createdAt);
    if (age > throttle) {
      // Expired: delete old and issue a new OTP
      await deleteOldGeneratedOtp(generateOtp.id);
      final otp = DBFunctions.generateRandomOtp();
      return await generateNewOtp(GenerateOtp(userId: userEntity.id, otp: otp));
    }
    // Still within throttle window: do not create a new OTP
    return null;
  }

  Future<GenerateOtp?> generateNewOtp(GenerateOtp generateOtp) async {
    var insertQuery = DBFunctions.generateInsertQueryFromClass(AppConfig.generateOtp, generateOtp.toTableJson);
    final query = insertQuery['query'] as String;
    final params = insertQuery['params'] as List<dynamic>;
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, otpKeys) as List;
    if (resList.isNotEmpty) {
      return GenerateOtp.fromJson(resList.first);
    }
    return null;
  }

  Future<GenerateOtp?> getOldGeneratedOtp(int id) async {
    final conditionData = DBFunctions.buildConditions({'user_id': id});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'SELECT ${otpKeys.join(',')} FROM ${AppConfig.generateOtp} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, otpKeys) as List;
    if (resList.isNotEmpty) {
      return GenerateOtp.fromJson(resList.first);
    }
    return null;
  }

  Future<void> deleteOldGeneratedOtp(int id) async {
    final conditionData = DBFunctions.buildConditions({'id': id});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'DELETE FROM ${AppConfig.generateOtp} WHERE ${conditions.join(' AND ')}';
    await connection.execute(Sql.named(query), parameters: params);
  }
}
