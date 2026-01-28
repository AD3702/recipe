import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:recipe/controller/auth_controller.dart';
import 'package:recipe/controller/mail_controller.dart';
import 'package:recipe/controller/payments_controller.dart';
import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/repositories/base/model/pagination_entity.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/user/model/user_entity.dart';
import 'package:recipe/repositories/user/model/user_documents_model.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

class UserController {
  late Connection connection;

  static UserController user = UserController._();

  UserController._() {
    connection = BaseRepository.baseRepository.connection;
    DBFunctions.getColumnNames(connection, AppConfig.userDetails).then((value) {
      keys = value;
    });
  }

  List<String> keys = [];

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
      var user = await createNewUser(superAdmin);
      PaymentsController.payments.upsertUserSubscription({
        "user_id": user?.id,
        "plan_code": "ULTRA",
        "status": "ACTIVE",
        "amount_paid": 0,
        "currency": "₹",
        "payment_provider": "SUPER_ADMIN",
        "provider_subscription_id": "pay_super_admin",
        "start_at": DateTime.now(),
        "end_at": DateTime(DateTime.now().year + 100),
      });
      await MailController.mail.sendUserCreationSuccessfulEmail([AppConfig.superAdminEmail, AppConfig.personalEmail], AppConfig.superAdminName, password);
    }
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

  ///GET USER LIST
  ///
  ///
  ///
  Future<(List<UserEntity>, PaginationEntity)> getUserList(Map<String, dynamic> requestBody, {bool isCook = false, int? viewerUserId}) async {
    int? pageSize = int.tryParse(requestBody['page_size'].toString());
    int? pageNumber = int.tryParse(requestBody['page_number'].toString());
    bool? isCook = bool.tryParse(requestBody['is_cook']?.toString() ?? '');
    // If requesting cooks only, force user_type filter.
    final bool isFollowing = bool.tryParse((requestBody['is_following'] ?? false).toString()) ?? false;
    requestBody.remove('is_following');
    requestBody.remove('is_cook');
    // Seeded shuffle (stable pagination) when is_shuffled=true
    final bool isShuffled = bool.tryParse((requestBody['is_shuffled'] ?? false).toString()) ?? false;
    requestBody.remove('is_shuffled');

    // Remove viewer/session keys so they don't become DB filters
    final String viewerKey = (requestBody['viewer_uuid'] ?? requestBody['viewer_id'] ?? requestBody['user_uuid'] ?? requestBody['session_id'] ?? '').toString();
    requestBody.remove('viewer_uuid');
    requestBody.remove('viewer_id');
    requestBody.remove('session_id');

    final int windowMinutes = int.tryParse((requestBody['shuffle_window_minutes'] ?? 1).toString()) ?? 1;
    requestBody.remove('shuffle_window_minutes');

    final int windowMs = windowMinutes * 60 * 1000;
    final int windowBucket = DateTime.now().millisecondsSinceEpoch ~/ windowMs;
    final String derivedSeed = '${viewerKey.trim()}::$windowBucket';
    final String shuffleSeed = (requestBody['shuffle_seed'] ?? derivedSeed).toString();
    requestBody.remove('shuffle_seed');
    final String safeSeed = shuffleSeed.replaceAll("'", "''");

    // Deterministic shuffle order (same seed => same order)
    // Using md5 on seed + id gives a stable pseudo-random ordering.
    final String shuffleOrderBy = isShuffled ? " ORDER BY md5('$safeSeed' || ud.id::text)" : " ORDER BY ud.is_admin_approved ASC, ud.id DESC";
    if (isCook ?? false) {
      requestBody['user_type'] = UserType.COOK.name;
    }
    final String? searchKeyword = requestBody['search_keyword']?.toString().trim();
    requestBody.remove('search_keyword');

    // ------------------------------
    // Manual query builder (no DBFunctions.buildConditions)
    // ------------------------------

    // Whitelist filters (anything else in requestBody is ignored)
    const filterable = <String>{
      'id',
      'uuid',
      'active',
      'deleted',
      'created_at',
      'updated_at',
      'user_type',
      'name',
      'email',
      'contact',
      'user_name',
      'is_contact_verified',
      'is_email_verified',
      'is_admin_approved',
    };

    final conditions = <String>[];
    final params = <dynamic>[];

    // Default: exclude deleted rows (same as includeDelete:false)
    conditions.add('(ud.deleted = false OR ud.deleted IS NULL)');

    // Default: active=true unless explicitly provided
    if (!requestBody.containsKey('active')) {
      conditions.add('ud.active = true');
    }

    // Apply exact-match filters from requestBody (whitelisted only)
    for (final entry in requestBody.entries) {
      final key = entry.key.toString();
      if (!filterable.contains(key)) continue;
      final val = entry.value;
      if (val == null) continue;
      final s = val.toString().trim();
      if (s.isEmpty) continue;

      // bool columns
      if (key == 'active' || key == 'deleted' || key == 'is_contact_verified' || key == 'is_email_verified' || key == 'is_admin_approved') {
        final b = bool.tryParse(s);
        if (b == null) continue;
        final idx = params.length;
        conditions.add('ud.$key = @$idx');
        params.add(b);
        continue;
      }

      // int columns
      if (key == 'id') {
        final i = int.tryParse(s);
        if (i == null) continue;
        final idx = params.length;
        conditions.add('ud.$key = @$idx');
        params.add(i);
        continue;
      }

      // other (string) columns
      final idx = params.length;
      conditions.add('ud.$key = @$idx');
      params.add(s);
    }

    // Pagination suffix (LIMIT/OFFSET) - built AFTER search is appended to avoid placeholder collisions
    final suffixParams = <dynamic>[];
    String suffix = '';

    // Ensure we always have at least one WHERE condition
    if (conditions.isEmpty) {
      conditions.add('true');
    }
    if (searchKeyword != null && searchKeyword.isNotEmpty) {
      final int idx = params.length;
      conditions.add(
        '(ud.name ILIKE @${idx} '
        'OR ud.email ILIKE @${idx} '
        'OR ud.user_name ILIKE @${idx} '
        'OR ud.contact ILIKE @${idx})',
      );
      params.add('%$searchKeyword%');
    }
    // Build pagination suffix AFTER all WHERE params are finalized
    if (pageSize != null && pageSize > 0) {
      final limitIdx = params.length + suffixParams.length;
      suffix += ' LIMIT @$limitIdx';
      suffixParams.add(pageSize);

      if (pageNumber != null && pageNumber > 0) {
        final offsetIdx = params.length + suffixParams.length;
        suffix += ' OFFSET @$offsetIdx';
        suffixParams.add((pageNumber - 1) * pageSize);
      }
    }
    // Default list query
    String query;
    String countQuery;
    List<dynamic> finalParams;
    List<dynamic> finalCountParams;
    List<String> selectKeys = keys.map((e) => e).toList();
    if (isFollowing && viewerUserId != null) {
      // IMPORTANT: DBFunctions.buildConditions uses numeric placeholders (@0, @1, ...).
      // Append viewerUserId at the end and reference it by its numeric index.
      final int viewerParamIndex = params.length + suffixParams.length;
      final int viewerCountParamIndex = params.length;

      // final prefixedConditions = _prefixConditionsWithAlias(conditions, 'ud', selectKeys);

      query =
          'SELECT ${selectKeys.map((e) => 'ud.$e').join(',')} '
          'FROM ${AppConfig.userDetails} ud '
          'INNER JOIN ${AppConfig.userFollowers} uf ON uf.user_following_id = ud.id '
          'WHERE ${conditions.join(' AND ')} AND uf.user_id = @$viewerParamIndex'
          '$shuffleOrderBy '
          '$suffix';

      countQuery =
          'SELECT COUNT(*) '
          'FROM ${AppConfig.userDetails} ud '
          'INNER JOIN ${AppConfig.userFollowers} uf ON uf.user_following_id = ud.id '
          'WHERE ${conditions.join(' AND ')} AND uf.user_id = @$viewerCountParamIndex';

      finalParams = [...params, ...suffixParams, viewerUserId];
      finalCountParams = [...params, viewerUserId];
    } else {
      var isAdminApprovedQuery = !isShuffled ? "" : "  AND ud.is_admin_approved = true";
      query = 'SELECT ${selectKeys.join(',')} FROM ${AppConfig.userDetails} ud WHERE ${conditions.join(' AND ')}$isAdminApprovedQuery$shuffleOrderBy $suffix';
      countQuery = 'SELECT COUNT(*) FROM ${AppConfig.userDetails} ud WHERE ${conditions.join(' AND ')}$isAdminApprovedQuery';
      finalParams = [...params, ...suffixParams];
      finalCountParams = [...params];
    }
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(finalParams));
    final countRes = await connection.execute(Sql.named(countQuery), parameters: _paramsListToMap(finalCountParams));
    int totalCount = countRes.first.first as int;
    PaginationEntity paginationEntity = PaginationEntity(totalCount: totalCount, pageSize: pageSize ?? totalCount, pageNumber: pageNumber ?? 1);
    var resList = DBFunctions.mapFromResultRow(res, selectKeys) as List;
    List<UserEntity> userList = [];

    // For every list response: add a `following` boolean indicating whether current viewer follows that user.
    // Only computed when viewerUserId is provided.
    final Set<int> followingIds = <int>{};
    if (viewerUserId != null && res.isNotEmpty) {
      try {
        final ids = res.map((r) => (r.first as int?) ?? 0).where((e) => e > 0).toList();
        if (ids.isNotEmpty) {
          final fRes = await connection.execute(
            Sql.named(
              'SELECT user_following_id '
              'FROM ${AppConfig.userFollowers} '
              'WHERE user_id = @0 AND user_following_id = ANY(@1)',
            ),
            parameters: _paramsListToMap([viewerUserId, ids]),
          );
          for (final row in fRes) {
            final id = (row.first as int?) ?? 0;
            if (id > 0) followingIds.add(id);
          }
        }
      } catch (_) {}
    }

    for (var user in resList) {
      userList.add(UserEntity.fromJson(user));
    }
    return (userList, paginationEntity);
  }

  Future<Response> getUserListResponse(Map<String, dynamic> requestBody, String userUuid, int userId) async {
    var userList = await getUserList(requestBody, viewerUserId: userId);
    Map<String, dynamic> response = {'status': 200, 'message': 'User list found successfully'};
    try {
      // Add `following` boolean for every item (does viewer follow this user?)
      Set<int> followingIds = <int>{};
      try {
        final ids = userList.$1.map((e) => e.id ?? 0).where((e) => e > 0).toList();
        if (ids.isNotEmpty) {
          final fRes = await connection.execute(
            Sql.named('SELECT user_following_id FROM ${AppConfig.userFollowers} WHERE user_id = @0 AND user_following_id = ANY(@1)'),
            parameters: _paramsListToMap([userId, ids]),
          );
          followingIds = fRes.map((r) => (r.first as int?) ?? 0).where((e) => e > 0).toSet();
        }
      } catch (_) {}

      response['data'] = userList.$1.map((e) {
        final m = e.toJson;
        m['following'] = followingIds.contains(e.id ?? -1);
        return m;
      }).toList();
      response['pagination'] = userList.$2.toJson;
      return Response(200, body: jsonEncode(response));
    } catch (e) {
      return Response(200, body: jsonEncode(response));
    }
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

      final bool notExpired = endDt == null ? false : endDt.isAfter(DateTime.now());
      final bool notCancelled = (status ?? '').toUpperCase() != 'CANCELLED';
      final bool isPremium = planCode != null && notExpired && notCancelled;
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

  ///GET USER DETAILS
  ///
  ///
  ///
  Future<Response> getUserFromUuidResponse(String uuid, int? userId) async {
    var userResponse = await getUserFromUuid(uuid);
    if (userResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'User not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      var responseJson = userResponse.toJson;
      // Subscription snapshot (premium/category/start/end)
      final int profileUserId = userResponse.id ?? 0;
      if (profileUserId > 0) {
        responseJson['subscription'] = await _getUserSubscriptionSnapshot(profileUserId);
      } else {
        responseJson['subscription'] = {'is_premium': false, 'category': 'FREE', 'plan_code': null, 'status': null, 'start_at': null, 'end_at': null};
      }
      Map<String, dynamic> response = {'status': 200, 'message': 'Cook found successfully'};
      if (userResponse.userType == UserType.COOK) {
        var document = await getUserDocumentsFromId(userResponse.id);
        if (document != null) {
          var responseData = userResponse.toJson;
          responseData['verification_document'] = BaseRepository.buildFileUrl(document.toJson['filePath']);
          responseJson = responseData;
        }
      }
      // Add `following`: whether current viewer follows this user
      bool isFollowingUser = false;
      if (userId != null) {
        try {
          final fr = await connection.execute(
            Sql.named('SELECT 1 FROM ${AppConfig.userFollowers} WHERE user_id = @0 AND user_following_id = @1 LIMIT 1'),
            parameters: _paramsListToMap([userId, userResponse.id]),
          );
          isFollowingUser = fr.isNotEmpty;
        } catch (_) {}
      }

      responseJson['following'] = isFollowingUser;

      response = {'status': 200, 'message': 'User found', 'data': responseJson};
      return Response(200, body: jsonEncode(response));
    }
  }

  ///GET USER PROFILE DETAILS
  ///
  ///
  ///
  Future<Response> getUserProfile(String uuid) async {
    var userResponse = await getUserFromUuid(uuid);

    if (userResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'User not found'};
      return Response(200, body: jsonEncode(response));
    } else {
      var responseJson = userResponse.toJson;
      final int profileUserId = userResponse.id;
      if (profileUserId > 0) {
        responseJson['subscription'] = await _getUserSubscriptionSnapshot(profileUserId);
      } else {
        responseJson['subscription'] = {'is_premium': false, 'category': 'FREE', 'plan_code': null, 'status': null, 'start_at': null, 'end_at': null};
      }
      if (userResponse.userType == UserType.COOK) {
        var document = await getUserDocumentsFromId(userResponse.id);
        if (document != null) {
          responseJson['verification_document'] = BaseRepository.buildFileUrl(document.toJson['filePath']);
        }
      }
      Map<String, dynamic> response = {'status': 200, 'message': 'User found', 'data': responseJson};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<UserEntity?> getUserFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.userDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return UserEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<UserEntity?> getUserFromId(int id) async {
    final conditionData = DBFunctions.buildConditions({'id': id});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.userDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return UserEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<UserDocumentsModel?> getUserDocumentsFromId(int id) async {
    final conditionData = DBFunctions.buildConditions({'user_id': id});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'SELECT ${UserDocumentsModel().toTableJson.keys.toList().join(',')} FROM ${AppConfig.cookVerificationDocuments} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
    var resList = DBFunctions.mapFromResultRow(res, UserDocumentsModel().toTableJson.keys.toList()) as List;
    if (resList.isNotEmpty) {
      return UserDocumentsModel.fromJson(resList.first);
    }
    return null;
  }

  Future<UserEntity?> getUserFromEmail(String email) async {
    final conditionData = DBFunctions.buildConditions({'email': email});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.userDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
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
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
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
  Future<Response> addUser(String request, {bool isRegister = false}) async {
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
    userEntity.isAdminApproved = !isRegister;
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
    response['data'] = userEntity?.toJson;
    if (userEntity != null) {
      MailController.mail.sendUserCreationSuccessfulEmail([userEntity.email!], userEntity.name!, password);
    }
    if (isRegister) {
      return await AuthController.auth.login(jsonEncode({'email': userEntity?.email, 'password': password}), showAdminValidation: false);
    }
    return Response(200, body: jsonEncode(response));
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

  ///UPLOAD COOK VERIFICATION DOCUMENT via multipart/form-data
  ///
  /// Endpoint should receive:
  /// - Field: file  (image file)
  /// - Optional field: mime_type
  ///
  /// Content-Type: multipart/form-data
  ///
  ///

  Future<Response> validateUserDocuments(Request request, int userId, String documentType) async {
    Map<String, dynamic> response = {'status': 400};
    final user = await getUserFromId(userId);
    if (user == null) {
      response['message'] = 'User not found with uuid $userId';
      return Response(404, body: jsonEncode(response));
    }
    if (user.userType != UserType.COOK) {
      response['message'] = 'Verification document is only allowed for user_type COOK';
      return Response.badRequest(body: jsonEncode(response));
    }

    var multipartResponse = await DBFunctions.multipartImageConfigure(request, 'cook_verification', 'verification_$userId');
    if (multipartResponse is Response) {
      return multipartResponse;
    }
    final doc = UserDocumentsModel(
      uuid: const Uuid().v8(),
      active: true,
      deleted: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      userId: userId,
      filePath: multipartResponse,
      documentType: documentType,
    );
    var userDocuments = await getUserDocumentsFromId(userId);
    if (userDocuments != null) {
      // Update existing document record
      final conditionData = DBFunctions.buildConditions({'uuid': userDocuments.uuid});
      final conditions = conditionData['conditions'] as List<String>;
      final params = conditionData['params'] as List<dynamic>;

      final updateData = {'file_path': multipartResponse, 'updated_at': DateTime.now().toIso8601String()};
      final setClauses = updateData.keys.map((key) => '$key = @${key}').toList();
      final updateParams = updateData.values.toList();

      final query = 'UPDATE ${AppConfig.cookVerificationDocuments} SET ${setClauses.join(', ')} WHERE ${conditions.join(' AND ')}';
      await connection.execute(Sql.named(query), parameters: [...updateParams, ...params]);

      response['status'] = 200;
      response['message'] = 'Cook verification document updated successfully';
      response['data'] = doc.toJson;
      return Response(200, body: jsonEncode(response));
    }
    final insertQuery = DBFunctions.generateInsertQueryFromClass(AppConfig.cookVerificationDocuments, doc.toTableJson);
    final query = insertQuery['query'] as String;
    final params = insertQuery['params'] as List<dynamic>;
    await connection.execute(Sql.named(query), parameters: params);

    response['status'] = 200;
    response['message'] = 'Cook verification document uploaded successfully';
    response['data'] = doc.toJson;
    return Response(200, body: jsonEncode(response));
  }

  Future<Response> uploadCookVerificationDocumentFormData(Request request, int userId) async {
    Response validationResponse = await validateUserDocuments(request, userId, 'IDENTITY_PROOF');
    return validationResponse;
  }

  Future<Response> uploadUserProfileImage(Request request, int userId) async {
    Response validationResponse = await validateUserDocuments(request, userId, 'PROFILE_IMAGE');
    return validationResponse;
  }

  ///DELETE USER
  ///
  ///
  ///
  Future<Response> deleteUserFromUuidResponse(String uuid) async {
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

  /// APPROVE / REJECT USER (Admin)
  ///
  /// Request body expects one of:
  /// - user_id: int
  /// - user_uuid: String
  ///
  /// And flags:
  /// - is_admin_approved: bool
  /// - is_rejected: bool
  ///
  /// Rules:
  /// - Both flags cannot be true at the same time.
  /// - If approving => is_rejected is forced to false.
  /// - If rejecting => is_admin_approved is forced to false.
  Future<Response> updateUserAdminApproval(int userId, bool isAdminApprovedRequest) async {
    final bool isAdminApprovedIn = isAdminApprovedRequest;
    final bool isRejectedIn = !isAdminApprovedRequest;

    if (userId == 0) {
      return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_id or user_uuid required'}));
    }

    bool isAdminApproved = isAdminApprovedIn;
    bool isRejected = isRejectedIn;

    if (isAdminApproved && isRejected) {
      return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'Both is_admin_approved and is_rejected cannot be true'}));
    }

    // Normalize flags
    if (isAdminApproved) {
      isRejected = false;
    }
    if (isRejected) {
      isAdminApproved = false;
    }

    // Fetch user to validate existence
    UserEntity? user;
    if (userId > 0) {
      user = await getUserFromId(userId);
    }

    if (user == null) {
      return Response(200, body: jsonEncode({'status': 404, 'message': 'User not found'}));
    }

    try {
      final String whereClause = 'id = @0';
      final dynamic whereValue = userId;

      // NOTE: assumes `user_details` has columns: is_admin_approved, is_rejected, updated_at
      await connection.execute(
        Sql.named(
          'UPDATE ${AppConfig.userDetails} '
          'SET is_admin_approved = @1, is_rejected = @2, updated_at = @3 '
          'WHERE $whereClause '
          'RETURNING ${keys.join(',')}',
        ),
        parameters: _paramsListToMap([whereValue, isAdminApproved, isRejected, DateTime.now().toIso8601String()]),
      );

      // Return latest user row
      final updatedUser = await getUserFromId(userId);

      return Response.ok(
        jsonEncode({
          'status': 200,
          'message': isAdminApproved ? 'User approved successfully' : (isRejected ? 'User rejected successfully' : 'User admin approval updated successfully'),
          'data': updatedUser?.toJson,
        }),
      );
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'status': 500, 'message': 'Failed to update user approval', 'error': e.toString()}));
    }
  }

  /// Toggle follow/unfollow for a user.
  ///
  /// Request body expects:
  /// - user_following_id: int (the profile user id to follow)
  /// - is_following: bool (true => follow, false => unfollow)
  ///
  /// Uses `${AppConfig.userFollowers}` table with fields:
  /// user_id, user_following_id, created_at, updated_at
  Future<Response> toggleUserFollowing(String request, int? userId) async {
    final Map<String, dynamic> data = jsonDecode(request);

    final int userFollowingId = int.tryParse(data['user_following_id']?.toString() ?? '') ?? 0;
    final bool isFollowing = parseBool(data['is_following'], false);

    if ((userId ?? 0) == 0 || userFollowingId == 0) {
      return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_id and user_following_id required'}));
    }

    // Check if relation already exists
    final checkQuery = 'SELECT 1 FROM ${AppConfig.userFollowers} WHERE user_id = @user_id AND user_following_id = @user_following_id LIMIT 1';

    final existing = await connection.execute(Sql.named(checkQuery), parameters: {'user_id': userId, 'user_following_id': userFollowingId});

    if (isFollowing) {
      if (existing.isNotEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already following'}));
      }

      final insertQuery =
          '''
        INSERT INTO ${AppConfig.userFollowers}
          (user_id, user_following_id, created_at, updated_at)
        VALUES
          (@user_id, @user_following_id, now(), now())
        RETURNING *
      ''';

      await connection.execute(Sql.named(insertQuery), parameters: {'user_id': userId, 'user_following_id': userFollowingId});

      // Optional counter update: followers++ for the followed user (best-effort)
      try {
        await connection.execute(Sql.named('UPDATE ${AppConfig.userDetails} SET followers = COALESCE(followers, 0) + 1 WHERE id = @0'), parameters: _paramsListToMap([userFollowingId]));
      } catch (_) {}

      return Response.ok(jsonEncode({'status': 200, 'message': 'User followed'}));
    } else {
      if (existing.isEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already unfollowed'}));
      }

      final deleteQuery =
          '''
        DELETE FROM ${AppConfig.userFollowers}
        WHERE user_id = @user_id
          AND user_following_id = @user_following_id
      ''';

      await connection.execute(Sql.named(deleteQuery), parameters: {'user_id': userId, 'user_following_id': userFollowingId});

      // Optional counter update: followers-- for the followed user (best-effort, never below 0)
      try {
        await connection.execute(
          Sql.named(
            'UPDATE ${AppConfig.userDetails} '
            'SET followers = GREATEST(COALESCE(followers, 0) - 1, 0) '
            'WHERE id = @0',
          ),
          parameters: _paramsListToMap([userFollowingId]),
        );
      } catch (_) {}

      return Response.ok(jsonEncode({'status': 200, 'message': 'User unfollowed'}));
    }
  }

  /// SUPER ADMIN DASHBOARD
  ///
  /// Returns aggregated stats for admin dashboard.
  /// Optional requestBody supports:
  /// - from: ISO string (inclusive)
  /// - to: ISO string (inclusive)
  /// If not provided, default is last 30 days for trend buckets.
  Future<Response> getSuperAdminDashboard({Map<String, dynamic>? requestBody}) async {
    DateTime _parseDt(dynamic v) {
      if (v == null) return DateTime.now();
      if (v is DateTime) return v;
      final s = v.toString().trim();
      if (s.isEmpty) return DateTime.now();
      try {
        return DateTime.parse(s);
      } catch (_) {
        return DateTime.now();
      }
    }

    final now = DateTime.now();
    final DateTime toDt = _parseDt(requestBody?['to'] ?? now.toIso8601String());
    final DateTime fromDt = _parseDt(requestBody?['from'] ?? now.subtract(const Duration(days: 30)).toIso8601String());

    // Keep sane ordering
    final DateTime from = fromDt.isAfter(toDt) ? toDt.subtract(const Duration(days: 30)) : fromDt;
    final DateTime to = toDt;

    // We cast created_at from text to timestamptz in SQL, so pass timestamptz params.
    final fromUtc = from.toUtc();
    final toUtc = to.toUtc();

    // NOTE: created_at columns in your DB appear to be stored as TEXT, so we use:
    // NULLIF(col::text,'')::timestamptz
    // This avoids date_trunc/type errors and compares as real timestamps.
    const String q = r'''
WITH
  range AS (
    SELECT @0::timestamptz AS from_ts, @1::timestamptz AS to_ts
  ),

  users_src AS (
    SELECT
      ud.*,
      UPPER(COALESCE(ud.user_type,'USER')) AS user_type_u,
      NULLIF(ud.created_at::text,'')::timestamptz AS created_ts
    FROM user_details ud
    WHERE (ud.deleted = false OR ud.deleted IS NULL)
  ),

  recipes_src AS (
    SELECT
      rd.*,
      NULLIF(rd.created_at::text,'')::timestamptz AS created_ts
    FROM recipe_details rd
    WHERE (rd.deleted = false OR rd.deleted IS NULL)
  ),

  subs_src AS (
    SELECT
      us.*,
      NULLIF(us.created_at::text,'')::timestamptz AS created_ts
    FROM user_subscriptions us
    WHERE (us.deleted = false OR us.deleted IS NULL)
  ),

  users_agg AS (
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE active = true)::int AS active,
      COUNT(*) FILTER (WHERE user_type_u = 'COOK')::int AS total_cooks,
      COUNT(*) FILTER (
        WHERE user_type_u = 'COOK'
          AND COALESCE(is_admin_approved,false) = false
          AND active = true
      )::int AS pending_cook_approvals,
      COUNT(*) FILTER (
        WHERE created_ts >= (SELECT from_ts FROM range)
          AND created_ts <= (SELECT to_ts FROM range)
      )::int AS new_in_range
    FROM users_src
  ),

  users_by_type AS (
    SELECT jsonb_agg(x ORDER BY (x->>'count')::int DESC) AS data
    FROM (
      SELECT jsonb_build_object(
        'userType', ut,
        'count', cnt
      ) AS x
      FROM (
        SELECT ud.user_type_u AS ut, COUNT(*)::int AS cnt
        FROM users_src ud
        GROUP BY ud.user_type_u
      ) s
    ) t
  ),

  signup_trend AS (
    SELECT jsonb_agg(x ORDER BY x->>'day') AS data
    FROM (
      SELECT jsonb_build_object(
        'day', to_char(d, 'YYYY-MM-DD'),
        'count', cnt
      ) AS x
      FROM (
        SELECT date_trunc('day', ud.created_ts) AS d, COUNT(*)::int AS cnt
        FROM users_src ud, range r
        WHERE ud.created_ts >= r.from_ts
          AND ud.created_ts <= r.to_ts
        GROUP BY date_trunc('day', ud.created_ts)
      ) s
    ) t
  ),

  recipes_agg AS (
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE active = true)::int AS active,
      COUNT(*) FILTER (
        WHERE created_ts >= (SELECT from_ts FROM range)
          AND created_ts <= (SELECT to_ts FROM range)
      )::int AS new_in_range,
      (SELECT COALESCE(SUM(COALESCE(rv.times,0)),0)::int FROM recipe_views rv)::int AS total_views,
      (SELECT COUNT(*) FROM recipe_wishlist rw)::int AS wishlist_count,
      (SELECT COUNT(*) FROM recipe_bookmark rb)::int AS bookmark_count
    FROM recipes_src
  ),

  category_distribution AS (
    SELECT jsonb_agg(x ORDER BY (x->>'count')::int DESC) AS data
    FROM (
      SELECT jsonb_build_object(
        'category', cat,
        'count', cnt
      ) AS x
      FROM (
        SELECT COALESCE(cd.name,'Unknown') AS cat, COUNT(*)::int AS cnt
        FROM recipes_src rd
        LEFT JOIN category_details cd ON cd.uuid = rd.category_uuid
        GROUP BY COALESCE(cd.name,'Unknown')
        ORDER BY COUNT(*) DESC
        LIMIT 15
      ) s
    ) t
  ),

  top_recipes AS (
    SELECT jsonb_agg(x) AS data
    FROM (
      SELECT jsonb_build_object(
        'id', rd.id,
        'uuid', rd.uuid,
        'name', rd.name,
        'views', COALESCE(rd.views,0),
        'likedCount', COALESCE(rd.liked_count,0),
        'bookmarkedCount', COALESCE(rd.bookmarked_count,0),
        'userUuid', rd.user_uuid,
        'categoryUuid', rd.category_uuid
      ) AS x
      FROM recipes_src rd
      ORDER BY COALESCE(rd.views,0) DESC, COALESCE(rd.liked_count,0) DESC
      LIMIT 10
    ) t
  ),

  revenue_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(amount_paid,0)) FILTER (
        WHERE created_ts >= (SELECT from_ts FROM range)
          AND created_ts <= (SELECT to_ts FROM range)
          AND (provider_payment_id IS NOT NULL OR provider_subscription_id IS NOT NULL)
      ), 0)::int AS total_in_range,

      COALESCE(SUM(COALESCE(amount_paid,0)) FILTER (
        WHERE created_ts >= (SELECT from_ts FROM range)
          AND created_ts <= (SELECT to_ts FROM range)
          AND COALESCE(recipe_id,0) = 0
          AND (provider_payment_id IS NOT NULL OR provider_subscription_id IS NOT NULL)
      ), 0)::int AS subscription_in_range,

      COALESCE(SUM(COALESCE(amount_paid,0)) FILTER (
        WHERE created_ts >= (SELECT from_ts FROM range)
          AND created_ts <= (SELECT to_ts FROM range)
          AND COALESCE(recipe_id,0) <> 0
          AND (provider_payment_id IS NOT NULL OR provider_subscription_id IS NOT NULL)
      ), 0)::int AS recipe_in_range
    FROM subs_src
  ),

  revenue_trend AS (
    SELECT jsonb_agg(x ORDER BY x->>'day') AS data
    FROM (
      SELECT jsonb_build_object(
        'day', to_char(d, 'YYYY-MM-DD'),
        'revenue', rev
      ) AS x
      FROM (
        SELECT date_trunc('day', us.created_ts) AS d,
               COALESCE(SUM(COALESCE(us.amount_paid,0)),0)::int AS rev
        FROM subs_src us, range r
        WHERE us.created_ts >= r.from_ts
          AND us.created_ts <= r.to_ts
          AND (us.provider_payment_id IS NOT NULL OR us.provider_subscription_id IS NOT NULL)
        GROUP BY date_trunc('day', us.created_ts)
      ) s
    ) t
  ),

  recent_transactions AS (
    SELECT jsonb_agg(x) AS data
    FROM (
      SELECT jsonb_build_object(
        'id', us.id,
        'uuid', us.uuid,
        'userId', us.user_id,
        'planCode', us.plan_code,
        'amountPaid', COALESCE(us.amount_paid,0),
        'currency', us.currency,
        'paymentProvider', us.payment_provider,
        'providerPaymentId', us.provider_payment_id,
        'providerSubscriptionId', us.provider_subscription_id,
        'recipeId', COALESCE(us.recipe_id,0),
        'status', us.status,
        'createdAt', us.created_at
      ) AS x
      FROM subs_src us
      ORDER BY us.created_ts DESC NULLS LAST
      LIMIT 20
    ) t
  ),

  active_plan_distribution AS (
    SELECT jsonb_agg(x ORDER BY (x->>'count')::int DESC) AS data
    FROM (
      SELECT jsonb_build_object(
        'planCode', pc,
        'count', cnt
      ) AS x
      FROM (
        SELECT UPPER(COALESCE(us.plan_code,'')) AS pc, COUNT(*)::int AS cnt
        FROM subs_src us
        WHERE COALESCE(us.recipe_id,0) = 0
          AND UPPER(COALESCE(us.status,'')) = 'ACTIVE'
        GROUP BY UPPER(COALESCE(us.plan_code,''))
      ) s
    ) t
  ),

  top_cooks AS (
    SELECT jsonb_agg(x) AS data
    FROM (
      SELECT jsonb_build_object(
        'id', ud.id,
        'uuid', ud.uuid,
        'name', ud.name,
        'userName', ud.user_name,
        'contact', ud.contact,
        'email', ud.email,
        'followers', COALESCE(ud.followers,0),
        'recipes', COALESCE(ud.recipes,0),
        'isAdminApproved', COALESCE(ud.is_admin_approved,false)
      ) AS x
      FROM users_src ud
      WHERE ud.active = true
        AND ud.user_type_u = 'COOK'
      ORDER BY COALESCE(ud.followers,0) DESC, COALESCE(ud.recipes,0) DESC
      LIMIT 10
    ) t
  )

SELECT jsonb_build_object(
  'status', 200,
  'message', 'Super admin dashboard loaded',
  'range', jsonb_build_object(
    'from', (SELECT to_char((SELECT from_ts FROM range), 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
    'to',   (SELECT to_char((SELECT to_ts FROM range),   'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))
  ),
  'users', jsonb_build_object(
    'total', (SELECT total FROM users_agg),
    'active', (SELECT active FROM users_agg),
    'totalCooks', (SELECT total_cooks FROM users_agg),
    'pendingCookApprovals', (SELECT pending_cook_approvals FROM users_agg),
    'newInRange', (SELECT new_in_range FROM users_agg),
    'byType', COALESCE((SELECT data FROM users_by_type), '[]'::jsonb)
  ),
  'recipes', jsonb_build_object(
    'total', (SELECT total FROM recipes_agg),
    'active', (SELECT active FROM recipes_agg),
    'newInRange', (SELECT new_in_range FROM recipes_agg),
    'totalViews', (SELECT total_views FROM recipes_agg),
    'wishlistCount', (SELECT wishlist_count FROM recipes_agg),
    'bookmarkCount', (SELECT bookmark_count FROM recipes_agg),
    'categoryDistribution', COALESCE((SELECT data FROM category_distribution), '[]'::jsonb),
    'topRecipes', COALESCE((SELECT data FROM top_recipes), '[]'::jsonb)
  ),
  'revenue', jsonb_build_object(
    'totalInRange', (SELECT total_in_range FROM revenue_agg),
    'subscriptionInRange', (SELECT subscription_in_range FROM revenue_agg),
    'recipeInRange', (SELECT recipe_in_range FROM revenue_agg)
  ),
  'transactions', jsonb_build_object(
    'recent', COALESCE((SELECT data FROM recent_transactions), '[]'::jsonb)
  ),
  'topCooks', COALESCE((SELECT data FROM top_cooks), '[]'::jsonb)
) AS data;
''';

    try {
      final res = await connection.execute(Sql.named(q), parameters: _paramsListToMap([fromUtc, toUtc]));

      if (res.isEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Super admin dashboard loaded', 'data': {}}), headers: {'Content-Type': 'application/json'});
      }

      final dynamic raw = res.first.first;
      // postgres.dart may return Map-like JSON or a String; normalize.
      final decoded = raw is String ? jsonDecode(raw) : (raw is Map ? raw : jsonDecode(raw.toString()));

      return Response.ok(jsonEncode(decoded), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'status': 500, 'message': 'Failed to load dashboard', 'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  }
}
