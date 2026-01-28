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
    final conditionData = DBFunctions.buildConditions({'email': email.toLowerCase()});
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

  /// postgres `Sql.named` expects a Map of named params.
  /// Our DBFunctions.buildConditions produces numeric placeholders like @0, @1...
  /// This converts a positional list into a named map: {'0': v0, '1': v1, ...}
  Map<String, dynamic> _paramsListToMap(List<dynamic> params) {
    final m = <String, dynamic>{};
    for (int i = 0; i < params.length; i++) {
      m['$i'] = params[i];
    }
    return m;
  }

  /// Subscription snapshot for a user (premium/category/plan/start/end).
  Future<Map<String, dynamic>> _getUserSubscriptionSnapshot(int profileUserId) async {
    try {
      // Fetch the latest active (or most recent) subscription row.
      // NOTE: This controller expects user_subscriptions columns: plan_code, start_at, end_at, status, active, deleted.
      final q = Sql.named('''
        SELECT
          us.plan_code,
          us.status,
          us.start_at,
          us.end_at,
          us.active,
          us.amount_paid,
          us.currency
        FROM ${AppConfig.userSubscriptions} us
        WHERE us.user_id = @0 AND us.provider_subscription_id is not NULL
          AND (us.deleted = false OR us.deleted IS NULL)
        ORDER BY us.active DESC, us.start_at DESC, us.created_at DESC
        LIMIT 1
      ''');

      final res = await connection.execute(q, parameters: _paramsListToMap([profileUserId]));
      if (res.isEmpty) {
        return {'is_premium': false, 'category': 'FREE', 'plan_code': null, 'status': null, 'start_at': null, 'end_at': null};
      }

      final row = res.first;
      final String? planCode = (row[0] ?? '').toString().trim().isEmpty ? null : (row[0] ?? '').toString();
      final String? status = (row[1] ?? '').toString().trim().isEmpty ? null : (row[1] ?? '').toString();
      final dynamic startAt = row[2];
      final dynamic endAt = row[3];
      final bool isActive = (row[4] as bool?) ?? false;
      final int amountPaid = int.tryParse(row[5]?.toString() ?? '') ?? 0;
      final String currency = (row[6] as String?) ?? '';

      // Premium definition: active row + end_at in future (if available) + status not CANCELLED.
      DateTime? endDt;
      if (endAt is DateTime) {
        endDt = endAt;
      } else if (endAt != null) {
        try {
          endDt = DateTime.parse(endAt.toString());
        } catch (_) {}
      }

      final bool notExpired = endDt == null ? isActive : endDt.isAfter(DateTime.now());
      final bool notCancelled = (status ?? '').toUpperCase() != 'CANCELLED';
      final bool isPremium = planCode != null && isActive && notExpired && notCancelled;
      return {
        'is_premium': isPremium,
        'amount_paid': amountPaid,
        'currency': currency,
        'plan_code': planCode,
        'status': status,
        'start_at': startAt is DateTime ? startAt.toIso8601String() : startAt?.toString(),
        'end_at': endAt is DateTime ? endAt.toIso8601String() : endAt?.toString(),
      };
    } catch (e) {
      // On any error, keep response safe.
      return {'is_premium': false, 'category': 'FREE', 'plan_code': null, 'status': null, 'start_at': null, 'end_at': null};
    }
  }

  ///LOGIN USER
  ///
  ///
  Future<Response> login(String request, {bool showAdminValidation = true}) async {
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
    print(showAdminValidation);
    if (!(userEntity?.isAdminApproved ?? false) && userEntity?.userType == UserType.COOK && showAdminValidation) {
      response['message'] = 'Please wait while your account is being approved by the admin';
      return Response.ok(jsonEncode(response));
    }
    response['status'] = 200;
    response['message'] = 'Login successful.';
    response['data'] = userEntity?.toJson;
    response['data']['token'] = BaseRepository.baseRepository.generateJwtToken(
      userId: userEntity?.id ?? 0,
      userName: userEntity?.email ?? '',
      userType: userEntity?.userType ?? UserType.USER,
      uuid: userEntity?.uuid ?? '',
      contact: userEntity?.contact ?? '',
      createdAt: userEntity?.createdAt ?? DateTime.now(),
      password: userEntity?.password ?? '',
    );
    response['data']['subscription'] = await _getUserSubscriptionSnapshot(userEntity!.id);
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
      String userName = jsonDecode(payloadJson)['userName'];
      String userType = jsonDecode(payloadJson)['userType'];
      userEntity = await getUserFromEmailAndUserType(userName, userType);
      response['data']['token'] = BaseRepository.baseRepository.generateJwtToken(
        userId: userEntity?.id ?? 0,
        userName: userEntity?.email ?? '',
        userType: userEntity?.userType ?? UserType.USER,
        uuid: userEntity?.uuid ?? '',
        contact: userEntity?.contact ?? '',
        createdAt: userEntity?.createdAt ?? DateTime.now(),
        password: userEntity?.password ?? '',
      );
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
