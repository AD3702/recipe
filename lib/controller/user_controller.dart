import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
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
    const filterable = <String>{'id', 'uuid', 'active', 'deleted', 'created_at', 'updated_at', 'user_type', 'name', 'email', 'contact', 'user_name', 'is_contact_verified', 'is_email_verified', 'is_admin_approved'};

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
        '(ud.name ILIKE @$idx '
        'OR ud.email ILIKE @$idx '
        'OR ud.user_name ILIKE @$idx '
        'OR ud.contact ILIKE @$idx)',
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
    // Our SELECT puts `recipes` as the last column (computed), so ensure the mapping keys match that order.
    final List<String> selectKeysForMapping = [...selectKeys.where((e) => e != 'recipes'), 'recipes'];
    if (isFollowing && viewerUserId != null) {
      // IMPORTANT: DBFunctions.buildConditions uses numeric placeholders (@0, @1, ...).
      // Append viewerUserId at the end and reference it by its numeric index.
      final int viewerParamIndex = params.length + suffixParams.length;
      final int viewerCountParamIndex = params.length;

      // SELECT with recipes overridden by subquery
      query =
          '''
SELECT
  ${selectKeys.where((e) => e != 'recipes').map((e) => 'ud.$e').join(',')},
  (
    SELECT COUNT(*)::int
    FROM ${AppConfig.recipeDetails} rd
    WHERE rd.user_uuid = ud.uuid
      AND (rd.deleted = false OR rd.deleted IS NULL)
  ) AS recipes
FROM ${AppConfig.userDetails} ud
INNER JOIN ${AppConfig.userFollowers} uf ON uf.user_following_id = ud.id
WHERE ${conditions.join(' AND ')} AND uf.user_id = @$viewerParamIndex
$shuffleOrderBy
$suffix
''';

      countQuery =
          'SELECT COUNT(*) '
          'FROM ${AppConfig.userDetails} ud '
          'INNER JOIN ${AppConfig.userFollowers} uf ON uf.user_following_id = ud.id '
          'WHERE ${conditions.join(' AND ')} AND uf.user_id = @$viewerCountParamIndex';

      finalParams = [...params, ...suffixParams, viewerUserId];
      finalCountParams = [...params, viewerUserId];
    } else {
      var isAdminApprovedQuery = !isShuffled ? "" : "  AND ud.is_admin_approved = true";
      // SELECT with recipes overridden by subquery
      query =
          '''
SELECT
  ${selectKeys.where((e) => e != 'recipes').map((e) => 'ud.$e').join(',')},
  (
    SELECT COUNT(*)::int
    FROM ${AppConfig.recipeDetails} rd
    WHERE rd.user_uuid = ud.uuid
      AND (rd.deleted = false OR rd.deleted IS NULL)
  ) AS recipes
FROM ${AppConfig.userDetails} ud
WHERE ${conditions.join(' AND ')}$isAdminApprovedQuery$shuffleOrderBy $suffix
''';
      countQuery = 'SELECT COUNT(*) FROM ${AppConfig.userDetails} ud WHERE ${conditions.join(' AND ')}$isAdminApprovedQuery';
      finalParams = [...params, ...suffixParams];
      finalCountParams = [...params];
    }
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(finalParams));
    final countRes = await connection.execute(Sql.named(countQuery), parameters: _paramsListToMap(finalCountParams));
    int totalCount = countRes.first.first as int;
    PaginationEntity paginationEntity = PaginationEntity(totalCount: totalCount, pageSize: pageSize ?? totalCount, pageNumber: pageNumber ?? 1);
    var resList = DBFunctions.mapFromResultRow(res, selectKeysForMapping) as List;
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
      if (user['user_type'] == 'COOK') {
        var document = await getUserDocumentsFromId(user['id']);
        user['verificationDocument'] = BaseRepository.buildFileUrl(document?.toJson['filePath']);
      }
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
        final ids = userList.$1.map((e) => e.id).where((e) => e > 0).toList();
        if (ids.isNotEmpty) {
          final fRes = await connection.execute(Sql.named('SELECT user_following_id FROM ${AppConfig.userFollowers} WHERE user_id = @0 AND user_following_id = ANY(@1)'), parameters: _paramsListToMap([userId, ids]));
          followingIds = fRes.map((r) => (r.first as int?) ?? 0).where((e) => e > 0).toSet();
        }
      } catch (_) {}

      response['data'] = userList.$1.map((e) {
        final m = e.toJson;
        m['following'] = followingIds.contains(e.id);
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
      final int profileUserId = userResponse.id;
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
          responseData['verificationDocument'] = BaseRepository.buildFileUrl(document.toJson['filePath']);
          responseJson = responseData;
        }
      }
      // Add `following`: whether current viewer follows this user
      bool isFollowingUser = false;
      if (userId != null) {
        try {
          final fr = await connection.execute(Sql.named('SELECT 1 FROM ${AppConfig.userFollowers} WHERE user_id = @0 AND user_following_id = @1 LIMIT 1'), parameters: _paramsListToMap([userId, userResponse.id]));
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
          responseJson['verificationDocument'] = BaseRepository.buildFileUrl(document.toJson['filePath']);
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
    final query =
        '''
SELECT
  ${keys.where((e) => e != 'recipes').map((e) => e).join(',')},
  (
    SELECT COUNT(*)::int
    FROM ${AppConfig.recipeDetails} rd
    WHERE rd.user_uuid = ${AppConfig.userDetails}.uuid
      AND (rd.deleted = false OR rd.deleted IS NULL)
  ) AS recipes
FROM ${AppConfig.userDetails}
WHERE ${conditions.join(' AND ')}
''';
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
    final List<String> keysForMapping = [...keys.where((e) => e != 'recipes'), 'recipes'];
    var resList = DBFunctions.mapFromResultRow(res, keysForMapping) as List;
    if (resList.isNotEmpty) {
      return UserEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<UserEntity?> getUserFromId(int id) async {
    final conditionData = DBFunctions.buildConditions({'id': id});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query =
        '''
SELECT
  ${keys.where((e) => e != 'recipes').map((e) => e).join(',')},
  (
    SELECT COUNT(*)::int
    FROM ${AppConfig.recipeDetails} rd
    WHERE rd.user_uuid = ${AppConfig.userDetails}.uuid
      AND (rd.deleted = false OR rd.deleted IS NULL)
  ) AS recipes
FROM ${AppConfig.userDetails}
WHERE ${conditions.join(' AND ')}
''';
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
    final List<String> keysForMapping = [...keys.where((e) => e != 'recipes'), 'recipes'];
    var resList = DBFunctions.mapFromResultRow(res, keysForMapping) as List;
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

    final query =
        '''
SELECT
  ${keys.where((e) => e != 'recipes').map((e) => e).join(',')},
  (
    SELECT COUNT(*)::int
    FROM ${AppConfig.recipeDetails} rd
    WHERE rd.user_uuid = ${AppConfig.userDetails}.uuid
      AND (rd.deleted = false OR rd.deleted IS NULL)
  ) AS recipes
FROM ${AppConfig.userDetails}
WHERE ${conditions.join(' AND ')}
''';
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
    final List<String> keysForMapping = [...keys.where((e) => e != 'recipes'), 'recipes'];
    var resList = DBFunctions.mapFromResultRow(res, keysForMapping) as List;
    if (resList.isNotEmpty) {
      return UserEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<UserEntity?> getUserFromContact(String contact) async {
    final conditionData = DBFunctions.buildConditions({'contact': contact});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final query =
        '''
SELECT
  ${keys.where((e) => e != 'recipes').map((e) => e).join(',')},
  (
    SELECT COUNT(*)::int
    FROM ${AppConfig.recipeDetails} rd
    WHERE rd.user_uuid = ${AppConfig.userDetails}.uuid
      AND (rd.deleted = false OR rd.deleted IS NULL)
  ) AS recipes
FROM ${AppConfig.userDetails}
WHERE ${conditions.join(' AND ')}
''';
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
    final List<String> keysForMapping = [...keys.where((e) => e != 'recipes'), 'recipes'];
    var resList = DBFunctions.mapFromResultRow(res, keysForMapping) as List;
    if (resList.isNotEmpty) {
      return UserEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<UserEntity?> getUserFromUserName(String userName) async {
    final conditionData = DBFunctions.buildConditions({'user_name': userName});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final query =
        '''
SELECT
  ${keys.where((e) => e != 'recipes').map((e) => e).join(',')},
  (
    SELECT COUNT(*)::int
    FROM ${AppConfig.recipeDetails} rd
    WHERE rd.user_uuid = ${AppConfig.userDetails}.uuid
      AND (rd.deleted = false OR rd.deleted IS NULL)
  ) AS recipes
FROM ${AppConfig.userDetails}
WHERE ${conditions.join(' AND ')}
''';
    final res = await connection.execute(Sql.named(query), parameters: _paramsListToMap(params));
    final List<String> keysForMapping = [...keys.where((e) => e != 'recipes'), 'recipes'];
    var resList = DBFunctions.mapFromResultRow(res, keysForMapping) as List;
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
    List<String> requiredParams = ['name', 'email', 'contact', 'user_type', 'user_name'];
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
    UserEntity? userWithUserName = await getUserFromUserName(userEntity.userName ?? '');
    if (userWithUserName != null) {
      response['message'] = 'User with username already exists';
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
    final doc = UserDocumentsModel(uuid: const Uuid().v8(), active: true, deleted: false, createdAt: DateTime.now(), updatedAt: DateTime.now(), userId: userId, filePath: multipartResponse, documentType: documentType);
    var userDocuments = await getUserDocumentsFromId(userId);
    if (userDocuments != null) {
      // Update existing document record
      final conditionData = DBFunctions.buildConditions({'uuid': userDocuments.uuid});
      final conditions = conditionData['conditions'] as List<String>;
      final params = conditionData['params'] as List<dynamic>;

      final updateData = {'file_path': multipartResponse, 'updated_at': DateTime.now().toIso8601String()};
      final setClauses = updateData.keys.map((key) => '$key = @$key').toList();
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

      return Response.ok(jsonEncode({'status': 200, 'message': isAdminApproved ? 'User approved successfully' : (isRejected ? 'User rejected successfully' : 'User admin approval updated successfully'), 'data': updatedUser?.toJson}));
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

  Future<Response> getSuperAdminDashboard({Map<String, dynamic>? requestBody}) async {
    DateTime _parseDt(dynamic v, DateTime fallback) {
      if (v == null) return fallback;
      if (v is DateTime) return v;
      final s = v.toString().trim();
      if (s.isEmpty) return fallback;
      try {
        return DateTime.parse(s);
      } catch (_) {
        return fallback;
      }
    }

    final now = DateTime.now();
    final bool hasFrom = requestBody?['from'] != null && requestBody!['from'].toString().trim().isNotEmpty;
    final bool hasTo = requestBody?['to'] != null && requestBody!['to'].toString().trim().isNotEmpty;

    final DateTime parsedFrom = hasFrom ? _parseDt(requestBody['from'], DateTime.utc(1970, 1, 1)) : DateTime.utc(1970, 1, 1);
    final DateTime parsedTo = hasTo ? _parseDt(requestBody['to'], now) : now;

    final DateTime from = parsedFrom.isAfter(parsedTo) ? parsedTo.subtract(const Duration(days: 30)) : parsedFrom;
    final DateTime to = parsedTo;

    final DateTime fromUtc = from.toUtc();
    final DateTime toUtc = to.toUtc();

    final String q =
        '''
WITH
  range_cte AS (
    SELECT @0::timestamptz AS from_ts, @1::timestamptz AS to_ts
  ),

  users_src AS (
    SELECT
      ud.id,
      ud.uuid,
      ud.name,
      ud.user_name,
      ud.contact,
      ud.email,
      COALESCE(ud.active, false) AS active,
      COALESCE(ud.deleted, false) AS deleted,
      COALESCE(ud.followers, 0) AS followers,
      COALESCE(ud.is_admin_approved, false) AS is_admin_approved,
      UPPER(COALESCE(ud.user_type, 'USER')) AS user_type_u,
      NULLIF(ud.created_at::text, '')::timestamptz AS created_ts
    FROM ${AppConfig.userDetails} ud
    WHERE (ud.deleted = false OR ud.deleted IS NULL)
  ),

  recipes_src AS (
    SELECT
      rd.id,
      rd.uuid,
      rd.name,
      rd.user_uuid,
      rd.category_uuid,
      COALESCE(rd.active, false) AS active,
      COALESCE(rd.deleted, false) AS deleted,
      COALESCE(rd.views, 0) AS views,
      COALESCE(rd.liked_count, 0) AS liked_count,
      COALESCE(rd.bookmarked_count, 0) AS bookmarked_count,
      NULLIF(rd.created_at::text, '')::timestamptz AS created_ts
    FROM ${AppConfig.recipeDetails} rd
    WHERE (rd.deleted = false OR rd.deleted IS NULL)
  ),

  subs_src AS (
    SELECT
      us.id,
      us.uuid,
      us.user_id,
      COALESCE(us.recipe_id, 0) AS recipe_id,
      us.plan_code,
      us.status,
      us.currency,
      us.payment_provider,
      us.provider_payment_id,
      us.provider_subscription_id,
      COALESCE(us.amount_paid, 0) AS amount_paid,
      COALESCE(us.active, false) AS active,
      NULLIF(us.created_at::text, '')::timestamptz AS created_ts,
      NULLIF(us.start_at::text, '')::timestamptz AS start_ts,
      NULLIF(us.end_at::text, '')::timestamptz AS end_ts,
      us.created_at
    FROM ${AppConfig.userSubscriptions} us
    WHERE (us.deleted = false OR us.deleted IS NULL)
  ),

  users_in_range AS (
    SELECT *
    FROM users_src
    WHERE created_ts >= (SELECT from_ts FROM range_cte)
      AND created_ts <= (SELECT to_ts FROM range_cte)
  ),

  recipes_in_range AS (
    SELECT *
    FROM recipes_src
    WHERE created_ts >= (SELECT from_ts FROM range_cte)
      AND created_ts <= (SELECT to_ts FROM range_cte)
  ),

  subs_in_range AS (
    SELECT *
    FROM subs_src
    WHERE created_ts >= (SELECT from_ts FROM range_cte)
      AND created_ts <= (SELECT to_ts FROM range_cte)
  ),

  recipe_counts_by_user AS (
    SELECT rd.user_uuid, COUNT(*)::int AS recipe_count
    FROM recipes_in_range rd
    GROUP BY rd.user_uuid
  ),

  recipe_purchase_stats AS (
    SELECT
      ss.recipe_id,
      COUNT(*)::int AS purchase_count,
      COALESCE(SUM(ss.amount_paid), 0)::int AS purchase_revenue
    FROM subs_in_range ss
    WHERE ss.recipe_id <> 0
      AND (
        ss.provider_payment_id IS NOT NULL
        OR ss.provider_subscription_id IS NOT NULL
        OR UPPER(COALESCE(ss.payment_provider, '')) = 'SUPER_ADMIN'
      )
    GROUP BY ss.recipe_id
  ),

  recipe_stats AS (
    SELECT
      rd.id,
      rd.uuid,
      rd.name,
      rd.user_uuid,
      rd.category_uuid,
      rd.views,
      rd.liked_count,
      rd.bookmarked_count,
      COALESCE(rps.purchase_count, 0) AS purchase_count,
      COALESCE(rps.purchase_revenue, 0) AS purchase_revenue,
      ROUND((rd.views * 1.0 + rd.liked_count * 2.0 + rd.bookmarked_count * 1.5 + COALESCE(rps.purchase_count, 0) * 3.0)::numeric, 2) AS performance_score
    FROM recipes_in_range rd
    LEFT JOIN recipe_purchase_stats rps ON rps.recipe_id = rd.id
  ),

  cook_stats AS (
    SELECT
      ud.id,
      ud.uuid,
      ud.name,
      ud.user_name,
      ud.contact,
      ud.email,
      COALESCE(ud.followers, 0) AS followers,
      COALESCE(ud.is_admin_approved, false) AS is_admin_approved,
      COALESCE(rc.recipe_count, 0) AS recipes,
      COALESCE(SUM(rs.views), 0)::int AS total_views,
      COALESCE(SUM(rs.liked_count), 0)::int AS total_likes,
      COALESCE(SUM(rs.bookmarked_count), 0)::int AS total_bookmarks,
      COALESCE(SUM(rs.purchase_count), 0)::int AS total_purchases,
      COALESCE(SUM(rs.purchase_revenue), 0)::int AS total_purchase_revenue,
      ROUND((COALESCE(ud.followers, 0) * 2.0 + COALESCE(rc.recipe_count, 0) * 3.0 + COALESCE(SUM(rs.views), 0) * 0.5 + COALESCE(SUM(rs.liked_count), 0) * 2.0 + COALESCE(SUM(rs.purchase_count), 0) * 3.0)::numeric, 2) AS performance_score
    FROM users_in_range ud
    LEFT JOIN recipe_counts_by_user rc ON rc.user_uuid = ud.uuid
    LEFT JOIN recipe_stats rs ON rs.user_uuid = ud.uuid
    WHERE ud.active = true
      AND ud.user_type_u = 'COOK'
    GROUP BY
      ud.id,
      ud.uuid,
      ud.name,
      ud.user_name,
      ud.contact,
      ud.email,
      ud.followers,
      ud.is_admin_approved,
      rc.recipe_count
  ),

  users_summary AS (
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE active = true)::int AS active,
      COUNT(*) FILTER (WHERE user_type_u = 'COOK')::int AS total_cooks,
      COUNT(*) FILTER (
        WHERE user_type_u = 'COOK'
          AND active = true
          AND COALESCE(is_admin_approved, false) = false
      )::int AS pending_cook_approvals,
      COUNT(*)::int AS new_in_range
    FROM users_in_range
  ),

  recipes_summary AS (
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE active = true)::int AS active,
      COUNT(*)::int AS new_in_range
    FROM recipes_in_range
  ),

  engagement_summary AS (
    SELECT
      COALESCE((
        SELECT SUM(COALESCE(rv.times, 0))::bigint
        FROM recipe_views rv
        WHERE NULLIF(rv.created_at::text, '')::timestamptz >= (SELECT from_ts FROM range_cte)
          AND NULLIF(rv.created_at::text, '')::timestamptz <= (SELECT to_ts FROM range_cte)
      ), 0)::int AS total_views,
      COALESCE((
        SELECT COUNT(*)::bigint
        FROM recipe_wishlist rw
        WHERE NULLIF(rw.created_at::text, '')::timestamptz >= (SELECT from_ts FROM range_cte)
          AND NULLIF(rw.created_at::text, '')::timestamptz <= (SELECT to_ts FROM range_cte)
      ), 0)::int AS wishlist_count,
      COALESCE((
        SELECT COUNT(*)::bigint
        FROM recipe_bookmark rb
        WHERE NULLIF(rb.created_at::text, '')::timestamptz >= (SELECT from_ts FROM range_cte)
          AND NULLIF(rb.created_at::text, '')::timestamptz <= (SELECT to_ts FROM range_cte)
      ), 0)::int AS bookmark_count,
      COALESCE((SELECT SUM(purchase_count)::bigint FROM recipe_purchase_stats), 0)::int AS total_recipe_purchases,
      COALESCE((SELECT SUM(purchase_revenue)::bigint FROM recipe_purchase_stats), 0)::int AS total_recipe_purchase_revenue
  ),

  revenue_summary AS (
    SELECT
      COALESCE(SUM(amount_paid) FILTER (
        WHERE (provider_payment_id IS NOT NULL OR provider_subscription_id IS NOT NULL OR UPPER(COALESCE(payment_provider, '')) = 'SUPER_ADMIN')
      ), 0)::int AS total_in_range,
      COALESCE(SUM(amount_paid) FILTER (
        WHERE recipe_id = 0
          AND (provider_payment_id IS NOT NULL OR provider_subscription_id IS NOT NULL OR UPPER(COALESCE(payment_provider, '')) = 'SUPER_ADMIN')
      ), 0)::int AS subscription_in_range,
      COALESCE(SUM(amount_paid) FILTER (
        WHERE recipe_id <> 0
          AND (provider_payment_id IS NOT NULL OR provider_subscription_id IS NOT NULL OR UPPER(COALESCE(payment_provider, '')) = 'SUPER_ADMIN')
      ), 0)::int AS recipe_in_range,
      COUNT(*) FILTER (
        WHERE (provider_payment_id IS NOT NULL OR provider_subscription_id IS NOT NULL OR UPPER(COALESCE(payment_provider, '')) = 'SUPER_ADMIN')
      )::int AS paid_transactions_in_range
    FROM subs_in_range
  ),

  user_type_distribution AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'userType', user_type_u,
          'count', cnt
        )
        ORDER BY cnt DESC, user_type_u ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT user_type_u, COUNT(*)::int AS cnt
      FROM users_in_range
      GROUP BY user_type_u
    ) s
  ),

  signup_trend AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'day', to_char(day_bucket, 'YYYY-MM-DD'),
          'count', cnt
        )
        ORDER BY day_bucket ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT date_trunc('day', created_ts) AS day_bucket, COUNT(*)::int AS cnt
      FROM users_in_range
      GROUP BY 1
    ) s
  ),

  recipe_trend AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'day', to_char(day_bucket, 'YYYY-MM-DD'),
          'count', cnt
        )
        ORDER BY day_bucket ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT date_trunc('day', created_ts) AS day_bucket, COUNT(*)::int AS cnt
      FROM recipes_in_range
      GROUP BY 1
    ) s
  ),

  revenue_trend AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'day', to_char(day_bucket, 'YYYY-MM-DD'),
          'revenue', revenue,
          'transactions', tx_count
        )
        ORDER BY day_bucket ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT
        date_trunc('day', created_ts) AS day_bucket,
        COALESCE(SUM(amount_paid), 0)::int AS revenue,
        COUNT(*)::int AS tx_count
      FROM subs_in_range
      WHERE (provider_payment_id IS NOT NULL OR provider_subscription_id IS NOT NULL OR UPPER(COALESCE(payment_provider, '')) = 'SUPER_ADMIN')
      GROUP BY 1
    ) s
  ),

  category_distribution AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'category', category_name,
          'count', cnt
        )
        ORDER BY cnt DESC, category_name ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT COALESCE(cd.name, 'Unknown') AS category_name, COUNT(*)::int AS cnt
      FROM recipes_in_range rd
      LEFT JOIN category_details cd ON cd.uuid = rd.category_uuid
      GROUP BY COALESCE(cd.name, 'Unknown')
      ORDER BY COUNT(*) DESC, COALESCE(cd.name, 'Unknown') ASC
      LIMIT 15
    ) s
  ),

  active_plan_distribution AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'planCode', plan_code_u,
          'count', cnt
        )
        ORDER BY cnt DESC, plan_code_u ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT UPPER(COALESCE(plan_code, 'UNKNOWN')) AS plan_code_u, COUNT(*)::int AS cnt
      FROM subs_in_range
      WHERE recipe_id = 0
        AND UPPER(COALESCE(status, '')) = 'ACTIVE'
        AND (
          provider_payment_id IS NOT NULL
          OR provider_subscription_id IS NOT NULL
          OR UPPER(COALESCE(payment_provider, '')) = 'SUPER_ADMIN'
        )
      GROUP BY 1
    ) s
  ),

  recent_transactions AS (
    SELECT COALESCE(
      jsonb_agg(tx ORDER BY created_ts_sort DESC NULLS LAST),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT
        created_ts AS created_ts_sort,
        jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'userId', user_id,
          'planCode', plan_code,
          'amountPaid', amount_paid,
          'currency', currency,
          'paymentProvider', payment_provider,
          'providerPaymentId', provider_payment_id,
          'providerSubscriptionId', provider_subscription_id,
          'recipeId', recipe_id,
          'status', status,
          'createdAt', created_at
        ) AS tx
      FROM subs_in_range
      WHERE provider_payment_id IS NOT NULL
         OR provider_subscription_id IS NOT NULL
         OR UPPER(COALESCE(payment_provider, '')) = 'SUPER_ADMIN'
      ORDER BY created_ts DESC NULLS LAST
      LIMIT 20
    ) s
  ),

  top_recipes AS (
    SELECT COALESCE(
      jsonb_agg(recipe_row ORDER BY performance_score DESC, views DESC, liked_count DESC, purchase_count DESC),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT
        performance_score,
        views,
        liked_count,
        purchase_count,
        jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'views', views,
          'likedCount', liked_count,
          'bookmarkedCount', bookmarked_count,
          'purchaseCount', purchase_count,
          'purchaseRevenue', purchase_revenue,
          'userUuid', user_uuid,
          'categoryUuid', category_uuid,
          'score', performance_score
        ) AS recipe_row
      FROM recipe_stats
      ORDER BY performance_score DESC, views DESC, liked_count DESC, purchase_count DESC
      LIMIT 10
    ) s
  ),

  top_cooks AS (
    SELECT COALESCE(
      jsonb_agg(cook_row ORDER BY performance_score DESC, followers DESC, recipes DESC),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT
        performance_score,
        followers,
        recipes,
        jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'userName', user_name,
          'contact', contact,
          'email', email,
          'followers', followers,
          'recipes', recipes,
          'totalViews', total_views,
          'totalLikes', total_likes,
          'totalBookmarks', total_bookmarks,
          'totalPurchases', total_purchases,
          'totalPurchaseRevenue', total_purchase_revenue,
          'isAdminApproved', is_admin_approved,
          'score', performance_score
        ) AS cook_row
      FROM cook_stats
      ORDER BY performance_score DESC, followers DESC, recipes DESC
      LIMIT 10
    ) s
  ),

  recipe_views_graph AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'value', views
        )
        ORDER BY views DESC, name ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT id, uuid, name, views
      FROM recipe_stats
      ORDER BY views DESC, name ASC
      LIMIT 10
    ) s
  ),

  recipe_likes_graph AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'value', liked_count
        )
        ORDER BY liked_count DESC, name ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT id, uuid, name, liked_count
      FROM recipe_stats
      ORDER BY liked_count DESC, name ASC
      LIMIT 10
    ) s
  ),

  recipe_purchases_graph AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'value', purchase_count,
          'revenue', purchase_revenue
        )
        ORDER BY purchase_count DESC, purchase_revenue DESC, name ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT id, uuid, name, purchase_count, purchase_revenue
      FROM recipe_stats
      ORDER BY purchase_count DESC, purchase_revenue DESC, name ASC
      LIMIT 10
    ) s
  ),

  cook_views_graph AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', COALESCE(name, user_name, email, contact),
          'value', total_views
        )
        ORDER BY total_views DESC, name ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT id, uuid, name, user_name, email, contact, total_views
      FROM cook_stats
      ORDER BY total_views DESC, name ASC
      LIMIT 10
    ) s
  ),

  cook_likes_graph AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', COALESCE(name, user_name, email, contact),
          'value', total_likes
        )
        ORDER BY total_likes DESC, name ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT id, uuid, name, user_name, email, contact, total_likes
      FROM cook_stats
      ORDER BY total_likes DESC, name ASC
      LIMIT 10
    ) s
  ),

  cook_purchases_graph AS (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', COALESCE(name, user_name, email, contact),
          'value', total_purchases,
          'revenue', total_purchase_revenue
        )
        ORDER BY total_purchases DESC, total_purchase_revenue DESC, name ASC
      ),
      '[]'::jsonb
    ) AS data
    FROM (
      SELECT id, uuid, name, user_name, email, contact, total_purchases, total_purchase_revenue
      FROM cook_stats
      ORDER BY total_purchases DESC, total_purchase_revenue DESC, name ASC
      LIMIT 10
    ) s
  ),

  most_viewed_recipe AS (
    SELECT COALESCE(
      (
        SELECT jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'views', views,
          'likedCount', liked_count,
          'purchaseCount', purchase_count,
          'purchaseRevenue', purchase_revenue,
          'userUuid', user_uuid
        )
        FROM recipe_stats
        ORDER BY views DESC, liked_count DESC, purchase_count DESC, id DESC
        LIMIT 1
      ),
      '{}'::jsonb
    ) AS data
  ),

  most_liked_recipe AS (
    SELECT COALESCE(
      (
        SELECT jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'views', views,
          'likedCount', liked_count,
          'purchaseCount', purchase_count,
          'purchaseRevenue', purchase_revenue,
          'userUuid', user_uuid
        )
        FROM recipe_stats
        ORDER BY liked_count DESC, views DESC, purchase_count DESC, id DESC
        LIMIT 1
      ),
      '{}'::jsonb
    ) AS data
  ),

  most_purchased_recipe AS (
    SELECT COALESCE(
      (
        SELECT jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'views', views,
          'likedCount', liked_count,
          'purchaseCount', purchase_count,
          'purchaseRevenue', purchase_revenue,
          'userUuid', user_uuid
        )
        FROM recipe_stats
        ORDER BY purchase_count DESC, purchase_revenue DESC, views DESC, id DESC
        LIMIT 1
      ),
      '{}'::jsonb
    ) AS data
  ),

  most_viewed_cook AS (
    SELECT COALESCE(
      (
        SELECT jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'userName', user_name,
          'followers', followers,
          'recipes', recipes,
          'totalViews', total_views,
          'totalLikes', total_likes,
          'totalPurchases', total_purchases,
          'totalPurchaseRevenue', total_purchase_revenue
        )
        FROM cook_stats
        ORDER BY total_views DESC, total_likes DESC, total_purchases DESC, id DESC
        LIMIT 1
      ),
      '{}'::jsonb
    ) AS data
  ),

  most_liked_cook AS (
    SELECT COALESCE(
      (
        SELECT jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'userName', user_name,
          'followers', followers,
          'recipes', recipes,
          'totalViews', total_views,
          'totalLikes', total_likes,
          'totalPurchases', total_purchases,
          'totalPurchaseRevenue', total_purchase_revenue
        )
        FROM cook_stats
        ORDER BY total_likes DESC, total_views DESC, total_purchases DESC, id DESC
        LIMIT 1
      ),
      '{}'::jsonb
    ) AS data
  ),

  most_purchased_cook AS (
    SELECT COALESCE(
      (
        SELECT jsonb_build_object(
          'id', id,
          'uuid', uuid,
          'name', name,
          'userName', user_name,
          'followers', followers,
          'recipes', recipes,
          'totalViews', total_views,
          'totalLikes', total_likes,
          'totalPurchases', total_purchases,
          'totalPurchaseRevenue', total_purchase_revenue
        )
        FROM cook_stats
        ORDER BY total_purchases DESC, total_purchase_revenue DESC, total_views DESC, id DESC
        LIMIT 1
      ),
      '{}'::jsonb
    ) AS data
  )

SELECT jsonb_build_object(
  'status', 200,
  'message', 'Super admin dashboard loaded',
  'range', jsonb_build_object(
    'from', to_char((SELECT from_ts FROM range_cte), 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'to', to_char((SELECT to_ts FROM range_cte), 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  ),
  'recipes', jsonb_build_object(
    'total', (SELECT total FROM recipes_summary),
    'active', (SELECT active FROM recipes_summary),
    'newInRange', (SELECT new_in_range FROM recipes_summary),
    'totalViews', (SELECT total_views FROM engagement_summary),
    'wishlistCount', (SELECT wishlist_count FROM engagement_summary),
    'bookmarkCount', (SELECT bookmark_count FROM engagement_summary),
    'totalPurchases', (SELECT total_recipe_purchases FROM engagement_summary),
    'totalPurchaseRevenue', (SELECT total_recipe_purchase_revenue FROM engagement_summary),
    'categoryDistribution', (SELECT data FROM category_distribution),
    'creationTrend', (SELECT data FROM recipe_trend),
    'topRecipes', (SELECT data FROM top_recipes)
  ),
  'topCooks', (SELECT data FROM top_cooks),
  'highlights', jsonb_build_object(
    'mostViewedRecipe', (SELECT data FROM most_viewed_recipe),
    'mostLikedRecipe', (SELECT data FROM most_liked_recipe),
    'mostPurchasedRecipe', (SELECT data FROM most_purchased_recipe),
    'mostViewedCook', (SELECT data FROM most_viewed_cook),
    'mostLikedCook', (SELECT data FROM most_liked_cook),
    'mostPurchasedCook', (SELECT data FROM most_purchased_cook)
  ),
  'graphs', jsonb_build_object(
    'recipeViews', (SELECT data FROM recipe_views_graph),
    'recipeLikes', (SELECT data FROM recipe_likes_graph),
    'recipePurchases', (SELECT data FROM recipe_purchases_graph),
    'cookViews', (SELECT data FROM cook_views_graph),
    'cookLikes', (SELECT data FROM cook_likes_graph),
    'cookPurchases', (SELECT data FROM cook_purchases_graph)
  ),
  'tables', jsonb_build_object(
    'topRecipesByPerformance', (SELECT data FROM top_recipes),
    'topCooksByPerformance', (SELECT data FROM top_cooks),
    'topRecipesByViews', (SELECT data FROM recipe_views_graph),
    'topRecipesByLikes', (SELECT data FROM recipe_likes_graph),
    'topRecipesByPurchases', (SELECT data FROM recipe_purchases_graph),
    'topCooksByViews', (SELECT data FROM cook_views_graph),
    'topCooksByLikes', (SELECT data FROM cook_likes_graph),
    'topCooksByPurchases', (SELECT data FROM cook_purchases_graph)
  ),
  'users', jsonb_build_object(
    'total', (SELECT total FROM users_summary),
    'active', (SELECT active FROM users_summary),
    'totalCooks', (SELECT total_cooks FROM users_summary),
    'pendingCookApprovals', (SELECT pending_cook_approvals FROM users_summary),
    'newInRange', (SELECT new_in_range FROM users_summary),
    'byType', (SELECT data FROM user_type_distribution),
    'signupTrend', (SELECT data FROM signup_trend)
  ),
  'revenue', jsonb_build_object(
    'totalInRange', (SELECT total_in_range FROM revenue_summary),
    'subscriptionInRange', (SELECT subscription_in_range FROM revenue_summary),
    'recipeInRange', (SELECT recipe_in_range FROM revenue_summary),
    'paidTransactionsInRange', (SELECT paid_transactions_in_range FROM revenue_summary),
    'trend', (SELECT data FROM revenue_trend),
    'activePlanDistribution', (SELECT data FROM active_plan_distribution)
  ),
  'transactions', jsonb_build_object(
    'recent', (SELECT data FROM recent_transactions)
  )
) AS data;
''';

    try {
      final res = await connection.execute(Sql.named(q), parameters: _paramsListToMap([fromUtc, toUtc]));

      if (res.isEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Super admin dashboard loaded', 'data': {}}), headers: {'Content-Type': 'application/json'});
      }

      final dynamic raw = res.first.first;
      final decoded = raw is String ? jsonDecode(raw) : (raw is Map ? raw : jsonDecode(raw.toString()));

      return Response.ok(jsonEncode(decoded), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'status': 500, 'message': 'Failed to load dashboard', 'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  }

  Future<Response> getSuperAdminReport({required String reportType, Map<String, dynamic>? range}) async {
    final String normalizedType = reportType.trim().toLowerCase();

    const List<String> supportedReportTypes = [
      'all_data',
      'user_overview',
      'user_growth',
      'user_type_distribution',
      'cook_growth',
      'cook_approval_status',
      'top_cooks_by_performance',
      'top_cooks_by_views',
      'top_cooks_by_likes',
      'top_cooks_by_purchases',
      'recipe_overview',
      'recipe_growth',
      'recipe_category_distribution',
      'top_recipes_by_performance',
      'top_recipes_by_views',
      'top_recipes_by_likes',
      'top_recipes_by_purchases',
      'revenue_overview',
      'revenue_trend',
      'subscription_plan_distribution',
      'transaction_summary',
      'recent_transactions',
      'engagement_summary',
      'highlights_summary',
    ];

    if (!supportedReportTypes.contains(normalizedType)) {
      return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'Unsupported report_type', 'reportCount': supportedReportTypes.length, 'supportedReportTypes': supportedReportTypes}), headers: {'Content-Type': 'application/json'});
    }

    final Response dashboardResponse = await getSuperAdminDashboard(requestBody: range);
    final String body = await dashboardResponse.readAsString();
    final Map<String, dynamic> decoded = jsonDecode(body) as Map<String, dynamic>;

    final Map<String, dynamic> users = ((decoded['users'] ?? {}) as Map).cast<String, dynamic>();
    final Map<String, dynamic> recipes = ((decoded['recipes'] ?? {}) as Map).cast<String, dynamic>();
    final Map<String, dynamic> revenue = ((decoded['revenue'] ?? {}) as Map).cast<String, dynamic>();
    final Map<String, dynamic> transactions = ((decoded['transactions'] ?? {}) as Map).cast<String, dynamic>();
    final Map<String, dynamic> highlights = ((decoded['highlights'] ?? {}) as Map).cast<String, dynamic>();
    final Map<String, dynamic> graphs = ((decoded['graphs'] ?? {}) as Map).cast<String, dynamic>();
    final Map<String, dynamic> tables = ((decoded['tables'] ?? {}) as Map).cast<String, dynamic>();
    final dynamic rangeData = decoded['range'];
    final dynamic topCooks = decoded['topCooks'];

    final Map<String, dynamic> reportMap = {
      'all_data': {
        'range': rangeData,
        'graphs': graphs,
        'tables': tables,
        'topCooks': topCooks,
        'highlights': highlights,
        'recipes': recipes,
        'transactions': transactions,
        'users': users,
        'revenue': revenue,
      },
      'user_overview': {
        'range': rangeData,
        'users': {'total': users['total'], 'active': users['active'], 'totalCooks': users['totalCooks'], 'pendingCookApprovals': users['pendingCookApprovals'], 'newInRange': users['newInRange']},
      },
      'user_growth': {'range': rangeData, 'signupTrend': users['signupTrend'] ?? []},
      'user_type_distribution': {'range': rangeData, 'byType': users['byType'] ?? []},
      'cook_growth': {'range': rangeData, 'totalCooks': users['totalCooks'], 'signupTrend': users['signupTrend'] ?? []},
      'cook_approval_status': {'range': rangeData, 'totalCooks': users['totalCooks'], 'pendingCookApprovals': users['pendingCookApprovals']},
      'top_cooks_by_performance': {'range': rangeData, 'topCooks': tables['topCooksByPerformance'] ?? topCooks ?? []},
      'top_cooks_by_views': {'range': rangeData, 'topCooks': tables['topCooksByViews'] ?? graphs['cookViews'] ?? []},
      'top_cooks_by_likes': {'range': rangeData, 'topCooks': tables['topCooksByLikes'] ?? graphs['cookLikes'] ?? []},
      'top_cooks_by_purchases': {'range': rangeData, 'topCooks': tables['topCooksByPurchases'] ?? graphs['cookPurchases'] ?? []},
      'recipe_overview': {
        'range': rangeData,
        'recipes': {
          'total': recipes['total'],
          'active': recipes['active'],
          'newInRange': recipes['newInRange'],
          'totalViews': recipes['totalViews'],
          'wishlistCount': recipes['wishlistCount'],
          'bookmarkCount': recipes['bookmarkCount'],
          'totalPurchases': recipes['totalPurchases'],
          'totalPurchaseRevenue': recipes['totalPurchaseRevenue'],
        },
      },
      'recipe_growth': {'range': rangeData, 'creationTrend': recipes['creationTrend'] ?? []},
      'recipe_category_distribution': {'range': rangeData, 'categoryDistribution': recipes['categoryDistribution'] ?? []},
      'top_recipes_by_performance': {'range': rangeData, 'topRecipes': tables['topRecipesByPerformance'] ?? recipes['topRecipes'] ?? []},
      'top_recipes_by_views': {'range': rangeData, 'topRecipes': tables['topRecipesByViews'] ?? graphs['recipeViews'] ?? []},
      'top_recipes_by_likes': {'range': rangeData, 'topRecipes': tables['topRecipesByLikes'] ?? graphs['recipeLikes'] ?? []},
      'top_recipes_by_purchases': {'range': rangeData, 'topRecipes': tables['topRecipesByPurchases'] ?? graphs['recipePurchases'] ?? []},
      'revenue_overview': {
        'range': rangeData,
        'revenue': {'totalInRange': revenue['totalInRange'], 'subscriptionInRange': revenue['subscriptionInRange'], 'recipeInRange': revenue['recipeInRange'], 'paidTransactionsInRange': revenue['paidTransactionsInRange']},
      },
      'revenue_trend': {'range': rangeData, 'trend': revenue['trend'] ?? []},
      'subscription_plan_distribution': {'range': rangeData, 'activePlanDistribution': revenue['activePlanDistribution'] ?? []},
      'transaction_summary': {'range': rangeData, 'paidTransactionsInRange': revenue['paidTransactionsInRange'], 'recentTransactionCount': ((transactions['recent'] ?? []) as List).length},
      'recent_transactions': {'range': rangeData, 'recent': transactions['recent'] ?? []},
      'engagement_summary': {
        'range': rangeData,
        'engagement': {'totalViews': recipes['totalViews'], 'wishlistCount': recipes['wishlistCount'], 'bookmarkCount': recipes['bookmarkCount'], 'totalPurchases': recipes['totalPurchases'], 'totalPurchaseRevenue': recipes['totalPurchaseRevenue']},
      },
      'highlights_summary': {'range': rangeData, 'highlights': highlights},
    };

    return Response.ok(
      jsonEncode({'status': 200, 'message': 'Report generated successfully', 'reportType': normalizedType, 'reportCount': supportedReportTypes.length, 'supportedReportTypes': supportedReportTypes, 'data': reportMap[normalizedType]}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  String _beautifyReportLabel(String value) {
    final normalized = value.replaceAll(RegExp(r'(?<=[a-z0-9])(?=[A-Z])'), '_').replaceAll('-', '_').replaceAll(RegExp(r'_+'), '_').trim();

    final words = normalized.split('_').map((e) => e.trim()).where((e) => e.isNotEmpty).map((e) => e.toLowerCase()).map((e) {
      const upperWords = {'id', 'uuid', 'api', 'crm', 'pdf', 'otp', 'upi', 'gst', 'faq', 'url', 'user', 'cook'};
      if (upperWords.contains(e)) return e.toUpperCase();
      return e[0].toUpperCase() + e.substring(1);
    }).toList();

    return words.join(' ');
  }

  String _pdfTextValue(dynamic value) {
    if (value == null) return '-';
    if (DateTime.tryParse(value.toString()) != null) {
      return DateFormat('dd/MM/yyyy hh:mm a').format(DateTime.parse(value));
    }
    final s = value.toString().trim();
    return s.isEmpty ? '-' : s;
  }

  bool _shouldExcludePdfKey(String key) {
    final normalized = key.trim().toLowerCase();
    if (normalized.isEmpty) return false;

    const exactMatches = {
      'id',
      'uuid',
      'user_id',
      'user_uuid',
      'recipe_id',
      'recipe_uuid',
      'category_id',
      'category_uuid',
      'cook_id',
      'cook_uuid',
      'provider_payment_id',
      'provider_subscription_id',
      'is_admin_approved',
      'is_email_verified',
      'is_contact_verified',
      'user_name'
      'username',
      'email',
      'contact',
    };

    if (exactMatches.contains(normalized)) return true;

    if (normalized.endsWith('_id') || normalized.endsWith('_uuid')) return true;
    if (normalized == 'userid' || normalized == 'useruuid') return true;
    if (normalized == 'recipeid' || normalized == 'recipeuuid') return true;
    if (normalized == 'categoryid' || normalized == 'categoryuuid') return true;
    if (normalized == 'cookid' || normalized == 'cookuuid') return true;
    if (normalized == 'providerpaymentid' || normalized == 'providersubscriptionid') return true;
    if (normalized == 'isadminapproved' || normalized == 'score') return true;
    if (normalized == 'userName' || normalized == 'username') return true;

    if (normalized.endsWith('id') || normalized.endsWith('uuid')) {
      return true;
    }

    return false;
  }

  pw.Widget _pdfInfoCard(String title, String value) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0')),
        borderRadius: pw.BorderRadius.circular(14),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(fontSize: 9, color: PdfColor.fromHex('#64748B'), fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 7),
          pw.Text(
            value,
            style: pw.TextStyle(fontSize: 15, color: PdfColor.fromHex('#0F172A'), fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );
  }

  pw.Widget _pdfSectionTitle(String title) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 10, bottom: 10),
      child: pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: pw.BoxDecoration(
          color: PdfColors.white,
          borderRadius: pw.BorderRadius.circular(12),
          border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0')),
        ),
        child: pw.Text(
          title,
          style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#0F172A')),
        ),
      ),
    );
  }

  pw.Widget _pdfMapAsCards(Map<String, dynamic> data) {
    final scalarEntries = data.entries.where((e) => !_shouldExcludePdfKey(e.key.toString())).where((e) => e.value == null || (e.value is! Map && e.value is! List)).toList();

    if (scalarEntries.isEmpty) {
      return pw.SizedBox.shrink();
    }

    final rows = scalarEntries.map((entry) => [_beautifyReportLabel(entry.key.toString()), _pdfTextValue(entry.value)]).toList();

    return pw.TableHelper.fromTextArray(
      headers: const ['Field', 'Value'],
      data: rows,
      headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 9),
      headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#22C55E')),
      cellStyle: pw.TextStyle(fontSize: 9, color: PdfColor.fromHex('#334155')),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      columnWidths: {0: const pw.FlexColumnWidth(2.2), 1: const pw.FlexColumnWidth(3.8)},
      // oddCellDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F8FAFC')),
      border: pw.TableBorder.all(color: PdfColor.fromHex('#E2E8F0'), width: 0.7),
    );
  }

  pw.Widget _pdfListAsTable(List<dynamic> items) {
    if (items.isEmpty) {
      return pw.Container(
        padding: const pw.EdgeInsets.all(14),
        decoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#F8FAFC'),
          border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0')),
          borderRadius: pw.BorderRadius.circular(12),
        ),
        child: pw.Text('No data available', style: pw.TextStyle(fontSize: 10, color: PdfColor.fromHex('#475569'))),
      );
    }

    final mapItems = items.whereType<Map>().toList();

    if (mapItems.length != items.length) {
      final rows = <List<String>>[];
      for (int i = 0; i < items.length; i++) {
        rows.add(['${i + 1}', _pdfTextValue(items[i])]);
      }

      return pw.TableHelper.fromTextArray(
        headers: const ['#', 'Value'],
        data: rows,
        headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 9),
        headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#22C55E')),
        cellStyle: pw.TextStyle(fontSize: 9, color: PdfColor.fromHex('#334155')),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        columnWidths: {0: const pw.FlexColumnWidth(0.8), 1: const pw.FlexColumnWidth(5.2)},
        // oddCellDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F8FAFC')),
        border: pw.TableBorder.all(color: PdfColor.fromHex('#E2E8F0'), width: 0.7),
      );
    }

    final headers = <String>{};
    for (final item in mapItems) {
      headers.addAll(item.keys.map((e) => e.toString()).where((key) => !_shouldExcludePdfKey(key)));
    }

    final headerList = headers.toList();
    if (headerList.isEmpty) {
      return pw.Container(
        padding: const pw.EdgeInsets.all(14),
        decoration: pw.BoxDecoration(
          color: PdfColor.fromHex('#F8FAFC'),
          border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0')),
          borderRadius: pw.BorderRadius.circular(12),
        ),
        child: pw.Text('No displayable data available', style: pw.TextStyle(fontSize: 10, color: PdfColor.fromHex('#475569'))),
      );
    }
    final rows = mapItems.map((item) => headerList.map((key) => _pdfTextValue(item[key])).toList()).toList();

    return pw.TableHelper.fromTextArray(
      headers: headerList.map(_beautifyReportLabel).toList(),
      data: rows,
      headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 9),
      headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#22C55E')),
      cellStyle: pw.TextStyle(fontSize: 8.5, color: PdfColor.fromHex('#334155')),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 6),
      // oddCellDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F8FAFC')),
      border: pw.TableBorder.all(color: PdfColor.fromHex('#E2E8F0'), width: 0.7),
    );
  }

  List<pw.Widget> _buildPdfContent(dynamic value, {String? title}) {
    final widgets = <pw.Widget>[];

    if (title != null && title.trim().isNotEmpty) {
      widgets.add(_pdfSectionTitle(title));
    }

    if (value == null) {
      widgets.add(
        pw.Container(
          padding: const pw.EdgeInsets.all(14),
          decoration: pw.BoxDecoration(
            color: PdfColor.fromHex('#F8FAFC'),
            border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0')),
            borderRadius: pw.BorderRadius.circular(12),
          ),
          child: pw.Text('No data available', style: pw.TextStyle(fontSize: 10, color: PdfColor.fromHex('#475569'))),
        ),
      );
      return widgets;
    }

    if (value is Map<String, dynamic>) {
      final scalarMap = <String, dynamic>{};
      final nestedEntries = <MapEntry<String, dynamic>>[];

      for (final entry in value.entries) {
        final key = entry.key.toString();
        if (key == 'range' || _shouldExcludePdfKey(key)) {
          continue;
        }

        if (entry.value is Map || entry.value is List) {
          nestedEntries.add(entry);
        } else {
          scalarMap[entry.key] = entry.value;
        }
      }

      if (scalarMap.isNotEmpty) {
        widgets.add(_pdfMapAsCards(scalarMap));
      }

      for (final entry in nestedEntries) {
        widgets.add(pw.SizedBox(height: 10));
        widgets.addAll(_buildPdfContent(entry.value, title: _beautifyReportLabel(entry.key.toString())));
      }
      return widgets;
    }

    if (value is Map) {
      return _buildPdfContent(value.cast<String, dynamic>(), title: title);
    }

    if (value is List) {
      widgets.add(_pdfListAsTable(value));
      return widgets;
    }

    widgets.add(
      pw.TableHelper.fromTextArray(
        headers: const ['Field', 'Value'],
        data: [
          ['Value', _pdfTextValue(value)],
        ],
        headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 9),
        headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#22C55E')),
        cellStyle: pw.TextStyle(fontSize: 9, color: PdfColor.fromHex('#334155')),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        columnWidths: {0: const pw.FlexColumnWidth(2.0), 1: const pw.FlexColumnWidth(4.0)},
        // oddCellDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F8FAFC')),
        border: pw.TableBorder.all(color: PdfColor.fromHex('#E2E8F0'), width: 0.7),
      ),
    );
    return widgets;
  }

  Future<Uint8List> _generateReportPdfBytes({required String reportType, required Map<String, dynamic> payload}) async {
    final pdf = pw.Document();
    final dynamic data = payload['data'];
    final dynamic range = payload['range'];
    final generatedAt = DateFormat('dd/MM/yyyy hh:mm a').format(DateTime.now());

    String fromText = 'Entire History';
    String toText = '-';

    if (range is Map) {
      final from = range['from'];
      final to = range['to'];
      if ((from ?? '').toString().trim().isNotEmpty || (to ?? '').toString().trim().isNotEmpty) {
        fromText = _pdfTextValue(from);
        toText = _pdfTextValue(to);
      }
    }

    final baseFont = pw.Font.helvetica();
    final boldFont = pw.Font.helveticaBold();
    final String reportLabel = _beautifyReportLabel(reportType);

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.fromLTRB(26, 24, 26, 28),
          theme: pw.ThemeData.withFont(base: baseFont, bold: boldFont),
        ),
        maxPages: 200,
        build: (context) => [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(22),
            decoration: pw.BoxDecoration(
              color: PdfColors.white,
              border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0')),
              borderRadius: pw.BorderRadius.circular(18),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Container(
                            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: pw.BoxDecoration(color: PdfColor.fromHex('#22C55E'), borderRadius: pw.BorderRadius.circular(20)),
                            child: pw.Text(
                              'DishConnect Admin Report',
                              style: pw.TextStyle(color: PdfColors.white, fontSize: 9, fontWeight: pw.FontWeight.bold),
                            ),
                          ),
                          pw.SizedBox(height: 14),
                          pw.Text(
                            reportLabel,
                            style: pw.TextStyle(color: PdfColor.fromHex('#14532D'), fontSize: 24, fontWeight: pw.FontWeight.bold),
                          ),
                          pw.SizedBox(height: 6),
                          pw.Text('Generated analytics summary for the selected report range.', style: pw.TextStyle(color: PdfColor.fromHex('#64748B'), fontSize: 10)),
                        ],
                      ),
                    ),
                    pw.SizedBox(width: 12),
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.white,
                        borderRadius: pw.BorderRadius.circular(14),
                        border: pw.Border.all(color: PdfColor.fromHex('#E2E8F0')),
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [
                          pw.Text(
                            'Generated At',
                            style: pw.TextStyle(fontSize: 8, color: PdfColor.fromHex('#64748B'), fontWeight: pw.FontWeight.bold),
                          ),
                          pw.SizedBox(height: 4),
                          pw.Text(
                            generatedAt,
                            style: pw.TextStyle(fontSize: 10, color: PdfColor.fromHex('#0F172A'), fontWeight: pw.FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                pw.SizedBox(height: 18),
                pw.Row(
                  children: [
                    pw.Expanded(child: _pdfInfoCard('From', fromText)),
                    pw.SizedBox(width: 10),
                    pw.Expanded(child: _pdfInfoCard('To', toText)),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 18),
          ..._buildPdfContent(data),
        ],
        footer: (context) => pw.Container(
          padding: const pw.EdgeInsets.only(top: 10),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('DishConnect', style: pw.TextStyle(fontSize: 9, color: PdfColor.fromHex('#64748B'))),
              pw.Text('Page ${context.pageNumber} of ${context.pagesCount}', style: pw.TextStyle(fontSize: 9, color: PdfColor.fromHex('#64748B'))),
            ],
          ),
        ),
      ),
    );

    return pdf.save();
  }

  Future<Response> getSuperAdminReportPdf({required String reportType, Map<String, dynamic>? range}) async {
    try {
      final reportResponse = await getSuperAdminReport(reportType: reportType, range: range);
      final reportBody = await reportResponse.readAsString();
      final Map<String, dynamic> payload = jsonDecode(reportBody) as Map<String, dynamic>;

      if ((payload['status'] ?? 500) != 200) {
        return Response(reportResponse.statusCode, body: jsonEncode(payload), headers: {'Content-Type': 'application/json'});
      }

      final normalizedPayload = {...payload, 'range': (payload['data'] is Map ? (payload['data'] as Map)['range'] : null), 'data': (payload['data'] is Map ? (payload['data'] as Map) : payload['data'])};

      final pdfBytes = await _generateReportPdfBytes(reportType: reportType, payload: normalizedPayload);
      final safeName = reportType.trim().toLowerCase().replaceAll(' ', '_');
      return Response.ok(
        pdfBytes,
        headers: {
          'Content-Type': 'application/pdf',
          'Content-Disposition': 'attachment; filename="${safeName}_report.pdf"',
          'Content-Length': pdfBytes.length.toString(),
          'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
          'Pragma': 'no-cache',
          'Expires': '0',
        },
      );
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'status': 500, 'message': 'Failed to generate PDF report', 'error': e.toString()}), headers: {'Content-Type': 'application/json'});
    }
  }
}
