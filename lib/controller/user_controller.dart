import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:recipe/controller/auth_controller.dart';
import 'package:recipe/controller/mail_controller.dart';
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
      createNewUser(superAdmin);
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

  /// Prefix simple column references with a table alias for JOIN queries.
  /// This avoids ambiguous columns like `active`, `deleted`, `user_type`.
  List<String> _prefixConditionsWithAlias(List<String> conditions, String alias, List<String> cols) {
    var out = conditions;
    for (final c in cols) {
      // word-boundary replace: active -> ud.active, etc.
      final re = RegExp(r'\b' + RegExp.escape(c) + r'\b');
      out = out.map((s) => s.replaceAllMapped(re, (m) => '$alias.$c')).toList();
    }
    return out;
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
    final String shuffleOrderBy = isShuffled ? " ORDER BY md5('$safeSeed' || ud.id::text)" : '';
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

      final prefixedConditions = _prefixConditionsWithAlias(conditions, 'ud', selectKeys);

      query =
          'SELECT ${selectKeys.map((e) => 'ud.$e').join(',')} '
          'FROM ${AppConfig.userDetails} ud '
          'INNER JOIN ${AppConfig.userFollowers} uf ON uf.user_following_id = ud.id '
          'WHERE ${prefixedConditions.join(' AND ')} AND uf.user_id = @$viewerParamIndex'
          '$shuffleOrderBy '
          '$suffix';

      countQuery =
          'SELECT COUNT(*) '
          'FROM ${AppConfig.userDetails} ud '
          'INNER JOIN ${AppConfig.userFollowers} uf ON uf.user_following_id = ud.id '
          'WHERE ${prefixedConditions.join(' AND ')} AND uf.user_id = @$viewerCountParamIndex';

      finalParams = [...params, ...suffixParams, viewerUserId];
      finalCountParams = [...params, viewerUserId];
    } else {
      query = 'SELECT ${selectKeys.join(',')} FROM ${AppConfig.userDetails} ud WHERE ${conditions.join(' AND ')}$shuffleOrderBy $suffix';
      countQuery = 'SELECT COUNT(*) FROM ${AppConfig.userDetails} ud WHERE ${conditions.join(' AND ')}';
      finalParams = [...params, ...suffixParams];
      finalCountParams = [...params];
    }
    print(query);
    print(finalParams);
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
        var document = await getUserDocumentsFromUuid(userResponse.uuid);
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
      var responseJson = userResponse.toJson; // Subscription snapshot (premium/category/start/end)
      final int profileUserId = userResponse.id ?? 0;
      if (profileUserId > 0) {
        responseJson['subscription'] = await _getUserSubscriptionSnapshot(profileUserId);
      } else {
        responseJson['subscription'] = {'is_premium': false, 'category': 'FREE', 'plan_code': null, 'status': null, 'start_at': null, 'end_at': null};
      }
      if (userResponse.userType == UserType.COOK) {
        var document = await getUserDocumentsFromUuid(userResponse.uuid);
        if (document != null) {
          var responseData = userResponse.toJson;
          responseData['verification_document'] = BaseRepository.buildFileUrl(document.toJson['filePath']);
          responseJson = responseData;
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

  Future<UserDocumentsModel?> getUserDocumentsFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'user_uuid': uuid});
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
    print(response);
    if (userEntity != null) {
      // MailController.mail.sendUserCreationSuccessfulEmail([userEntity.email!], userEntity.name!, password);
    }
    if (isRegister) {
      return await AuthController.auth.login(jsonEncode({'email': userEntity?.email, 'password': password}));
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

  ///UPLOAD COOK VERIFICATION DOCUMENT via multipart/form-data
  ///
  /// Endpoint should receive:
  /// - Field: file  (image file)
  /// - Optional field: mime_type
  ///
  /// Content-Type: multipart/form-data
  ///
  ///

  Future<Response> validateUserDocuments(Request request, String userUuid, String documentType) async {
    Map<String, dynamic> response = {'status': 400};
    final user = await getUserFromUuid(userUuid);
    if (user == null) {
      response['message'] = 'User not found with uuid $userUuid';
      return Response(404, body: jsonEncode(response));
    }
    if (user.userType != UserType.COOK) {
      response['message'] = 'Verification document is only allowed for user_type COOK';
      return Response.badRequest(body: jsonEncode(response));
    }

    var multipartResponse = DBFunctions.multipartImageConfigure(request, 'cook_verification', 'verification_$userUuid');
    if (multipartResponse is Response) {
      return multipartResponse;
    }
    final doc = UserDocumentsModel(
      uuid: const Uuid().v8(),
      active: true,
      deleted: false,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      userUuid: userUuid,
      filePath: multipartResponse,
      documentType: documentType,
    );
    var userDocuments = await getUserDocumentsFromUuid(userUuid);
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

  Future<Response> uploadCookVerificationDocumentFormData(Request request, String userUuid) async {
    Response validationResponse = await validateUserDocuments(request, userUuid, 'IDENTITY_PROOF');
    return validationResponse;
  }

  Future<Response> uploadUserProfileImage(Request request, String userUuid) async {
    Response validationResponse = await validateUserDocuments(request, userUuid, 'PROFILE_IMAGE');
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

  Future<(Map<int, Map<String, int>>, Set<int>)> _getCookStatsByUuids(Map<int, String> cookIds, {required int viewerUserId}) async {
    final Map<int, Map<String, int>> out = {};
    final followingIds = <int>{};
    if ((cookIds.keys.toList()).isEmpty) return (out, followingIds);
    // Prepare default map entries.
    for (final u in (cookIds.keys.toList())) {
      final id = u;
      out[id] = {'totalRecipes': 0, 'totalViews': 0, 'totalLikes': 0, 'totalFollowers': 0};
    }

    // NOTE: Table names below are common conventions used in this project.
    // If your AppConfig uses different table constants/column names, adjust here.

    // 1) Total Recipes per cook
    try {
      final qRecipes =
          ''
          'SELECT user_uuid, COUNT(*)::int AS total_recipes '
          'FROM ${AppConfig.recipeDetails} '
          'WHERE user_uuid = ANY(@ids) '
          'GROUP BY user_uuid';

      final res = await connection.execute(Sql.named(qRecipes), parameters: {'ids': (cookIds.values.toList())});
      for (final row in res) {
        final uuid = (row[0] ?? '').toString();
        final v = (row[1] ?? 0) as int;
        var id = cookIds.keys.toList()[cookIds.values.toList().indexWhere((e) => e == uuid)];
        if (out.containsKey(id)) out[id]!['totalRecipes'] = v;
      }
    } catch (_) {
      // Keep zeros if table/columns not available yet.
    }

    // 2) Total Views on cook's recipes (sum of view.times)
    try {
      final qViews =
          ''
          'SELECT r.user_uuid, COALESCE(SUM(v.times), 0)::int AS total_views '
          'FROM ${AppConfig.recipeViews} v '
          'JOIN ${AppConfig.recipeDetails} r ON r.id = v.recipe_id '
          'WHERE r.user_uuid = ANY(@ids) '
          'GROUP BY r.user_uuid';

      final res = await connection.execute(Sql.named(qViews), parameters: {'ids': cookIds.values.toList()});

      for (final row in res) {
        final uuid = (row[0] ?? '').toString();
        final v = (row[1] ?? 0) as int;
        var id = cookIds.keys.toList()[cookIds.values.toList().indexWhere((e) => e == uuid)];
        if (out.containsKey(id)) out[id]!['totalViews'] = v;
      }
    } catch (_) {
      // Keep zeros.
    }

    // 3) Total Likes on cook's recipes
    // Assumes a wishlist/engagement table with `recipe_uuid` and `is_like`.
    try {
      final qLikes =
          ''
          'SELECT r.user_uuid, COUNT(*)::int AS total_likes '
          'FROM ${AppConfig.recipeWishlist} w '
          'JOIN ${AppConfig.recipeDetails} r ON r.id = w.recipe_id '
          'WHERE r.user_uuid = ANY(@ids) '
          'GROUP BY r.user_uuid';

      final res = await connection.execute(Sql.named(qLikes), parameters: {'ids': cookIds.values.toList()});

      for (final row in res) {
        final uuid = (row[0] ?? '').toString();
        final v = (row[1] ?? 0) as int;
        var id = cookIds.keys.toList()[cookIds.values.toList().indexWhere((e) => e == uuid)];
        if (out.containsKey(id)) out[id]!['totalLikes'] = v;
      }
    } catch (_) {
      // Keep zeros.
    }

    // 4) Total Followers for cook + isFollowing for viewer (single query)
    try {
      final qFollowers =
          '''
        SELECT
          user_following_id AS cook_id,
          COUNT(*)::int AS total_followers,
          MAX(CASE WHEN user_id = @viewer_id THEN 1 ELSE 0 END)::int AS is_following
        FROM ${AppConfig.userFollowers}
        WHERE user_following_id = ANY(@ids)
        GROUP BY user_following_id
      ''';

      final res = await connection.execute(Sql.named(qFollowers), parameters: {'ids': cookIds.keys.toList(), 'viewer_id': viewerUserId});

      for (final row in res) {
        final cookId = (row[0] ?? 0) as int;
        final total = (row[1] ?? 0) as int;
        final isFollowing = (row[2] ?? 0) as int;

        if (out.containsKey(cookId)) out[cookId]!['totalFollowers'] = total;
        if (isFollowing == 1) followingIds.add(cookId);
      }
    } catch (_) {
      // Keep zeros.
    }

    return (out, followingIds);
  }
}
