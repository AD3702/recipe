import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:recipe/controller/category_controller.dart';
import 'package:recipe/controller/payments_controller.dart';
import 'package:recipe/controller/user_controller.dart';
import 'package:recipe/repositories/base/model/base_entity.dart';
import 'package:recipe/repositories/base/model/pagination_entity.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/category/model/category_entity.dart';
import 'package:recipe/repositories/recipe/model/recipe_entity.dart';
import 'package:recipe/repositories/recipe/model/recipe_views_table.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:uuid/uuid.dart';

class RecipeController {
  late Connection connection;

  RecipeController._() {
    connection = BaseRepository.baseRepository.connection;
    DBFunctions.getColumnNames(connection, AppConfig.recipeDetails).then((value) {
      keys = value;
    });
  }

  static RecipeController recipe = RecipeController._();

  List<String> keys = [];
  Map<String, String>? _categoryNameCache;
  DateTime? _categoryNameCacheAt;

  List<String> _parseJsonList(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    if (value is String && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is List) {
          return decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {
        // ignore invalid json
      }
    }
    return [];
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

  /// postgres `Sql.named` expects a Map of named params.
  /// Our DBFunctions.buildConditions produces numeric placeholders like @0, @1...
  /// This converts a positional list into a named map: {'0': v0, '1': v1, ...}
  List _paramsMapToList(Map<String, dynamic> params) {
    final m = [];
    for (int i = 0; i < params.length; i++) {
      m.add(params['$i']);
    }
    return m;
  }

  Future<Map<String, String>> _getUserNameMap(Set<String> userUuids) async {
    if (userUuids.isEmpty) return {};

    final query =
        'SELECT uuid, name FROM ${AppConfig.userDetails} '
        'WHERE uuid = ANY(@uuids) AND (deleted = false OR deleted IS NULL)';

    final res = await connection.execute(Sql.named(query), parameters: {'uuids': userUuids.toList()});

    final map = <String, String>{};
    for (final row in res) {
      map[row[0] as String] = row[1] as String;
    }
    return map;
  }

  Future<Map<String, String>> _getCategoryNameMap() async {
    // Category table is small and changes rarely; cache to avoid extra DB calls per request.
    final now = DateTime.now();
    if (_categoryNameCache != null && _categoryNameCacheAt != null && now.difference(_categoryNameCacheAt!).inMinutes < 10) {
      return _categoryNameCache!;
    }

    final query =
        'SELECT uuid, name FROM ${AppConfig.categoryDetails} '
        'WHERE deleted = false';

    final res = await connection.execute(Sql.named(query));

    final map = <String, String>{};
    for (final row in res) {
      map[row[0] as String] = row[1] as String;
    }

    _categoryNameCache = map;
    _categoryNameCacheAt = now;
    return map;
  }

  ///GET CATEGORY LIST
  ///
  ///
  ///
  Future<(List<RecipeEntity>, PaginationEntity)> getRecipeList(Map<String, dynamic> requestBody, String? userUuid, int? userId) async {
    int? pageSize = int.tryParse((requestBody['page_size'] ?? '').toString());
    int? pageNumber = int.tryParse(requestBody['page_number'].toString());
    final String? searchKeyword = (requestBody['search_keyword'])?.toString().trim();
    requestBody.remove('search_keyword');
    final bool isShuffled = bool.tryParse((requestBody['is_shuffled'] ?? '').toString()) ?? true;
    final bool isBookmarkedOnly = bool.tryParse((requestBody['is_bookmarked'] ?? '').toString()) ?? false;
    final bool isFollowed = bool.tryParse((requestBody['is_followed'] ?? '').toString()) ?? false;
    final bool isPurchasedOnly = bool.tryParse((requestBody['is_purchased'] ?? '').toString()) ?? false;
    // Remove custom flags before building base conditions
    requestBody.remove('is_shuffled');
    requestBody.remove('is_bookmarked');
    requestBody.remove('is_followed');
    requestBody.remove('is_purchased');

    // Category filter: accept List<String> in request (category_uuid or categoryUuid)
    // DB stores category_uuid as a JSON array string/jsonb (e.g. ["uuid1","uuid2"]) so we filter via jsonb operators.
    final List<String> filterCategoryUuids = _parseJsonList(requestBody['category_uuid']).map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList();

    // Remove so it doesn't become an equality condition by DBFunctions.buildConditions
    requestBody.remove('category_uuid');

    // Seeded shuffle (stable pagination) when is_shuffled=true
    final String viewerKey = (requestBody['viewer_uuid'] ?? requestBody['viewer_id'] ?? requestBody['user_uuid'] ?? requestBody['session_id'] ?? '').toString();
    final int windowMinutes = int.tryParse((requestBody['shuffle_window_minutes'] ?? 1).toString()) ?? 1;
    final int windowMs = windowMinutes * 60 * 1000;
    final int windowBucket = DateTime.now().millisecondsSinceEpoch ~/ windowMs;
    final String derivedSeed = '${viewerKey.trim()}::$windowBucket';
    final String shuffleSeed = (requestBody['shuffle_seed'] ?? derivedSeed).toString();
    final String safeSeed = shuffleSeed.replaceAll("'", "''");

    // Remove these so they don't become DB filters
    requestBody.remove('viewer_uuid');
    requestBody.remove('viewer_id');
    // requestBody.remove('user_uuid');
    requestBody.remove('session_id');
    requestBody.remove('shuffle_window_minutes');
    requestBody.remove('shuffle_seed');

    final conditionData = DBFunctions.buildConditions(requestBody, searchKeys: [], limit: null, offset: null);

    final conditions = (conditionData['conditions'] as List<String>);
    final params = (conditionData['params'] as List<dynamic>);

    // Apply category list filter (ANY match)
    // Uses jsonb ?| operator which checks whether the jsonb array contains ANY of the strings in the provided text[].
    // If you ever need ALL match, replace ?| with ?&.
    if (filterCategoryUuids.isNotEmpty) {
      final int idx = params.length;
      conditions.add("(COALESCE(rd.category_uuid::jsonb, '[]'::jsonb) ?| @$idx)");
      params.add(filterCategoryUuids);
    }

    // Manual search across recipe fields (name, ingredients, note)
    if (searchKeyword != null && searchKeyword.isNotEmpty) {
      final int idx = params.length;
      conditions.add(
        '(name ILIKE @$idx '
        'OR note ILIKE @$idx '
        'OR ingredients::text ILIKE @$idx)',
      );
      params.add('%$searchKeyword%');
    }

    // Purchased-only filter
    final bool hasUser = (userId ?? 0) > 0;

    // Build pagination suffix AFTER all WHERE params are finalized
    final suffixParams = <dynamic>[];
    String suffix = '';
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

    // Use persisted counters directly from recipe_details (no extra joins / aggregates)
    final String viewsSelect = 'COALESCE(rd.views, 0) AS views';
    final String likedCountSelect = 'COALESCE(rd.liked_count, 0) AS liked_count';
    final String bookmarkedCountSelect = 'COALESCE(rd.bookmarked_count, 0) AS bookmarked_count';

    // Ordering:
    // - If shuffled: stable shuffle per viewer+time window (for stable pagination)
    // - Else: latest first (deterministic)
    final String orderClause = isShuffled ? " ORDER BY md5(COALESCE(rd.uuid::text, '') || '$safeSeed')" : ' ORDER BY rd.id DESC';

    final selectKeys = keys.map((k) => 'rd.$k').join(',');
    final extraKeys = ['is_liked', 'is_bookmarked', 'views', 'liked_count', 'bookmarked_count', 'access_tier', 'price', 'currency', 'is_purchased'];

    // Prefix recipe_details columns with alias `rd.` inside generated conditions
    final whereSql = conditions.map((c) => c.replaceAllMapped(RegExp(r'\b(uuid|id|active|deleted|created_at|updated_at|user_uuid|name|note|ingredients)\b'), (m) => 'rd.${m[0]}')).join(' AND ');

    // If followed-only, restrict to recipes whose owner is followed by this viewer.
    // We join user_details (owner) to map rd.user_uuid -> owner user id, then user_followers.
    final bool useFollowJoin = isFollowed && (userId ?? 0) > 0;

    final String followJoinSql = useFollowJoin
        ? 'INNER JOIN ${AppConfig.userDetails} u ON u.uuid = rd.user_uuid AND (u.deleted = false OR u.deleted IS NULL) '
              'INNER JOIN ${AppConfig.userFollowers} uf ON uf.user_following_id = u.id AND uf.user_id = @viewer_user_id '
        : '';

    final String followJoinCountSql = useFollowJoin
        ? 'INNER JOIN ${AppConfig.userDetails} u ON u.uuid = rd.user_uuid AND (u.deleted = false OR u.deleted IS NULL) '
              'INNER JOIN ${AppConfig.userFollowers} uf ON uf.user_following_id = u.id AND uf.user_id = @viewer_user_id '
        : '';

    // If bookmarked-only, restrict to recipes present in bookmark table for this user.
    // Uses INNER JOIN for good performance.
    final bool useBookmarkJoin = isBookmarkedOnly && (userId ?? 0) > 0;

    final String bookmarkJoinSql = useBookmarkJoin ? 'INNER JOIN ${AppConfig.recipeBookmark} rbf ON rbf.recipe_id = rd.id AND rbf.user_id = @viewer_user_id ' : '';

    final String bookmarkJoinCountSql = useBookmarkJoin ? 'INNER JOIN ${AppConfig.recipeBookmark} rbf ON rbf.recipe_id = rd.id AND rbf.user_id = @viewer_user_id ' : '';

    final bool usePurchaseJoin = isPurchasedOnly && (userId ?? 0) > 0;

    final String purchaseJoinSql = usePurchaseJoin ? 'INNER JOIN ${AppConfig.userSubscriptions} usb ON usb.recipe_id = rd.id AND usb.user_id = @viewer_user_id ' : '';

    final String purchaseJoinCountSql = usePurchaseJoin ? 'INNER JOIN ${AppConfig.userSubscriptions} usb ON usb.recipe_id = rd.id AND usb.user_id = @viewer_user_id ' : '';

    // Enrich response flags for the current user (no filtering)
    final String likeJoinSql = hasUser ? 'LEFT JOIN ${AppConfig.recipeWishlist} rw ON rw.recipe_id = rd.id AND rw.user_id = @viewer_user_id ' : '';

    // For is_bookmarked in normal list, use a LEFT JOIN (avoid clashing with the bookmarked-only INNER JOIN alias)
    final String bookmarkFlagJoinSql = (!isBookmarkedOnly && hasUser) ? 'LEFT JOIN ${AppConfig.recipeBookmark} rbl ON rbl.recipe_id = rd.id AND rbl.user_id = @viewer_user_id ' : '';

    // Flags (computed via LEFT JOINs when userId is available)
    String likedSelect = 'false AS is_liked';
    String bookmarkedSelect = isBookmarkedOnly ? 'true AS is_bookmarked' : 'false AS is_bookmarked';

    if (hasUser) {
      likedSelect = 'CASE WHEN rw.recipe_id IS NULL THEN false ELSE true END AS is_liked';
      if (!isBookmarkedOnly) {
        bookmarkedSelect = 'CASE WHEN rbl.recipe_id IS NULL THEN false ELSE true END AS is_bookmarked';
      }
    }

    // Purchase flag (computed from user_subscriptions)
    final String purchasedSelect = hasUser
        ? 'EXISTS(SELECT 1 FROM ${AppConfig.userSubscriptions} usb '
              'WHERE usb.recipe_id = rd.id '
              'AND usb.user_id = @viewer_user_id '
              'AND usb.provider_payment_id IS NOT NULL '
              'AND (usb.deleted = false OR usb.deleted IS NULL)) AS is_purchased'
        : 'false AS is_purchased';

    final String pricingSelect =
        "COALESCE(rp.access_tier, 'FREE') AS access_tier, "
        "COALESCE(NULLIF(rp.price::text, '')::int, 0) AS price, "
        "COALESCE(rp.currency, 'INR') AS currency";

    final String pricingJoinSql =
        'LEFT JOIN ${AppConfig.recipePricing} rp '
        'ON rp.recipe_id = rd.id AND (rp.deleted = false OR rp.deleted IS NULL) ';

    final query =
        'SELECT $selectKeys, $likedSelect, $bookmarkedSelect, $viewsSelect, $likedCountSelect, $bookmarkedCountSelect, $pricingSelect, $purchasedSelect '
        'FROM ${AppConfig.recipeDetails} rd '
        '$pricingJoinSql'
        '$followJoinSql'
        '$bookmarkJoinSql'
        '$likeJoinSql'
        '$bookmarkFlagJoinSql'
        '$purchaseJoinSql'
        'WHERE $whereSql'
        '$orderClause '
        '$suffix';

    final countQuery =
        'SELECT COUNT(*) '
        'FROM ${AppConfig.recipeDetails} rd '
        '$followJoinCountSql'
        '$bookmarkJoinCountSql'
        '$purchaseJoinCountSql'
        'WHERE $whereSql';

    final listParams = [...params, ...suffixParams];
    final countParams = [...params];

    final listParamMap = _paramsListToMap(listParams);
    final countParamMap = _paramsListToMap(countParams);

    // Used by likeJoinSql, bookmarkFlagJoinSql, and also by followed-only / bookmarked-only joins
    if ((userId ?? 0) > 0) {
      listParamMap['viewer_user_id'] = userId;
      if (isBookmarkedOnly || isFollowed || isPurchasedOnly) {
        countParamMap['viewer_user_id'] = userId;
      }
    }

    DBFunctions.printSqlWithParamsMap(query, listParamMap);

    final res = await connection.execute(Sql.named(query), parameters: listParamMap);
    final countRes = await connection.execute(Sql.named(countQuery), parameters: countParamMap);

    int totalCount = countRes.first.first as int;
    PaginationEntity paginationEntity = PaginationEntity(totalCount: totalCount, pageSize: pageSize ?? totalCount, pageNumber: pageNumber ?? 1);

    // Map results including computed flags
    final mapped = DBFunctions.mapFromResultRow(res, [...keys, ...extraKeys]) as List;

    final Set<String> userUuidSet = {};
    final Set<String> categoryUuidSet = {};

    for (final row in mapped) {
      final u = row['user_uuid'];
      if (u != null && u.toString().isNotEmpty) {
        userUuidSet.add(u.toString());
      }

      final cats = _parseJsonList(row['category_uuid']);
      for (final c in cats) {
        categoryUuidSet.add(c.toString());
      }
    }

    final userNameMap = await _getUserNameMap(userUuidSet);
    final categoryNameMap = await _getCategoryNameMap();

    final List<RecipeEntity> recipeList = [];
    for (final row in mapped) {
      final recipeModel = RecipeEntity.fromJson(row);

      // computed booleans
      recipeModel.isLiked = parseBool(row['is_liked'], false);
      recipeModel.isBookmarked = parseBool(row['is_bookmarked'], false);
      recipeModel.views = parseInt(row['views']);
      recipeModel.likedCount = parseInt(row['liked_count']);
      recipeModel.bookmarkedCount = parseInt(row['bookmarked_count']);
      recipeModel.accessTier = (row['access_tier'] ?? 'FREE').toString();
      recipeModel.price = parseInt(row['price']);
      recipeModel.currency = (row['currency'] ?? 'INR').toString();
      recipeModel.isPurchased = parseBool(row['is_purchased'], false);
      // Optimized enrichment
      recipeModel.recipeImageUrls = recipeModel.recipeImageUrls?.map((e) => BaseRepository.buildFileUrl(e)).toList() ?? [];

      recipeModel.userName = userNameMap[recipeModel.userUuid] ?? '';

      recipeModel.categoryName = (recipeModel.categoryUuids ?? []).map((e) => categoryNameMap[e]).whereType<String>().toList();
      recipeList.add(recipeModel);
    }

    return (recipeList, paginationEntity);
  }

  Future<RecipeEntity?> getRecipeFromUuid(String uuid, String? userUuid, {bool liveUrl = true, required int? userId}) async {
    // Persisted counters on recipe_details
    final String viewsSelect = 'COALESCE(rd.views, 0) AS views';
    final String likedCountSelect = 'COALESCE(rd.liked_count, 0) AS liked_count';
    final String bookmarkedCountSelect = 'COALESCE(rd.bookmarked_count, 0) AS bookmarked_count';

    final selectKeys = keys.map((k) => 'rd.$k').join(',');
    final String userNameSelect = 'COALESCE(u.name, \'\') AS user_name';

    final bool hasUser = (userId ?? 0) > 0;

    // If user is known, compute flags via LEFT JOINs (no filtering, only enrichment)
    final String likedSelect = hasUser ? 'CASE WHEN rw.recipe_id IS NULL THEN false ELSE true END AS is_liked' : 'false AS is_liked';
    final String bookmarkedSelect = hasUser ? 'CASE WHEN rb.recipe_id IS NULL THEN false ELSE true END AS is_bookmarked' : 'false AS is_bookmarked';

    // Purchase flag (computed from user_subscriptions)
    final String purchasedSelect = hasUser
        ? 'EXISTS(SELECT 1 FROM ${AppConfig.userSubscriptions} us '
              'WHERE us.recipe_id = rd.id '
              'AND us.user_id = @user_id '
              'AND us.provider_payment_id IS NOT NULL '
              'AND (us.deleted = false OR us.deleted IS NULL)) AS is_purchased'
        : 'false AS is_purchased';

    final String likeJoinSql = hasUser ? 'LEFT JOIN ${AppConfig.recipeWishlist} rw ON rw.recipe_id = rd.id AND rw.user_id = @user_id ' : '';

    final String bookmarkJoinSql = hasUser ? 'LEFT JOIN ${AppConfig.recipeBookmark} rb ON rb.recipe_id = rd.id AND rb.user_id = @user_id ' : '';

    // Pricing (joined from recipe_pricing)
    final String pricingSelect =
        "COALESCE(rp.access_tier, 'FREE') AS access_tier, "
        "COALESCE(NULLIF(rp.price::text, '')::int, 0) AS price, "
        "COALESCE(rp.currency, 'INR') AS currency";

    final String pricingJoinSql =
        'LEFT JOIN ${AppConfig.recipePricing} rp '
        'ON rp.recipe_id = rd.id AND (rp.deleted = false OR rp.deleted IS NULL) ';

    final query =
        'SELECT $selectKeys, $userNameSelect, $likedSelect, $bookmarkedSelect, $viewsSelect, $likedCountSelect, $bookmarkedCountSelect, $pricingSelect, $purchasedSelect '
        'FROM ${AppConfig.recipeDetails} rd '
        '$pricingJoinSql'
        'LEFT JOIN ${AppConfig.userDetails} u '
        '  ON u.uuid = rd.user_uuid AND (u.deleted = false OR u.deleted IS NULL) '
        '$likeJoinSql'
        '$bookmarkJoinSql'
        'WHERE rd.uuid = @uuid '
        '  AND (rd.deleted = false OR rd.deleted IS NULL) '
        'LIMIT 1';

    final paramMap = <String, dynamic>{'uuid': uuid};
    if (hasUser) {
      paramMap['user_id'] = userId;
    }

    final res = await connection.execute(Sql.named(query), parameters: paramMap);

    final mapped =
        DBFunctions.mapFromResultRow(res, [...keys, 'user_name', 'is_liked', 'is_bookmarked', 'views', 'liked_count', 'bookmarked_count', 'access_tier', 'price', 'currency', 'is_purchased']) as List;

    if (mapped.isNotEmpty) {
      final row = mapped.first;
      final recipeModel = RecipeEntity.fromJson(row);

      recipeModel.isLiked = parseBool(row['is_liked'], false);
      recipeModel.isBookmarked = parseBool(row['is_bookmarked'], false);
      recipeModel.views = parseInt(row['views']);
      recipeModel.likedCount = parseInt(row['liked_count']);
      recipeModel.bookmarkedCount = parseInt(row['bookmarked_count']);
      recipeModel.accessTier = (row['access_tier'] ?? 'FREE').toString();
      recipeModel.price = parseInt(row['price']);
      recipeModel.currency = (row['currency'] ?? 'INR').toString();
      recipeModel.isPurchased = parseBool(row['is_purchased'], false);
      recipeModel.recipeImageUrls = !liveUrl ? recipeModel.recipeImageUrls : recipeModel.recipeImageUrls?.map((e) => BaseRepository.buildFileUrl(e)).toList() ?? [];

      recipeModel.userName = (row['user_name'] ?? '').toString();

      final categoryNameMap = await _getCategoryNameMap();
      recipeModel.categoryName = (recipeModel.categoryUuids ?? []).map((e) => categoryNameMap[e]).whereType<String>().toList();

      return recipeModel;
    }

    return null;
  }

  Future<Response> getRecipeListResponse(Map<String, dynamic> requestBody, String? userUuid, int? recipeId) async {
    var recipeList = await getRecipeList(requestBody, userUuid, recipeId);
    Map<String, dynamic> response = {'status': 200, 'message': 'Recipe list found successfully'};
    response['data'] = recipeList.$1.map((e) => e.toJson).toList();
    response['pagination'] = recipeList.$2.toJson;
    return Response(200, body: jsonEncode(response));
  }

  ///GET CATEGORY DETAILS
  ///
  ///
  ///
  Future<Response> getRecipeFromUuidResponse(String uuid, String? userUuid, int? userId) async {
    var recipeResponse = await getRecipeFromUuid(uuid, userUuid, userId: userId);

    if (recipeResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Recipe not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      Map<String, dynamic> response = {'status': 200, 'message': 'Recipe found', 'data': recipeResponse.toJson};
      return Response(200, body: jsonEncode(response));
    }
  }

  ///ADD CATEGORY
  ///
  ///
  Future<Response> addRecipe(String request, String? userUuid, int? userId) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    List<String> requiredParams = ['name'];
    List<String> requestParams = requestData.keys.toList();
    var res = DBFunctions.checkParamValidRequest(requestParams, requiredParams);
    if (res != null) {
      response['message'] = res;
      return Response.badRequest(body: jsonEncode(response));
    }
    // Pricing fields (optional) for monetization
    final Map<String, dynamic> pricingBody = {
      'access_tier': (requestData['access_tier'] ?? requestData['accessTier'] ?? 'FREE').toString(),
      'price': requestData['price'],
      'currency': (requestData['currency'] ?? 'INR').toString(),
    };

    // Remove pricing keys so they do not get inserted into recipe_details
    requestData.remove('access_tier');
    requestData.remove('accessTier');
    requestData.remove('price');
    requestData.remove('currency');

    RecipeEntity? recipeEntity = RecipeEntity.fromJson(requestData);
    recipeEntity = await createNewRecipe(recipeEntity, pricing: pricingBody);
    response['status'] = 200;
    response['message'] = 'Recipe created successfully';
    response['data'] = (await getRecipeFromUuid(recipeEntity!.uuid, userUuid, userId: userId))?.toJson;
    return Response(201, body: jsonEncode(response));
  }

  /// Updates persisted counters on recipe_details and aggregated counters on user_details (owner of recipe).
  /// NOTE: recipe_details stores owner as user_uuid, so we join user_details to get numeric owner id.
  Future<void> _bumpCountersForRecipeUuid({required int recipeId, int viewsDelta = 0, int likedDelta = 0, int bookmarkDelta = 0, int recipeDelta = 0}) async {
    if (recipeId <= 0) return;
    if (viewsDelta == 0 && likedDelta == 0 && bookmarkDelta == 0) return;

    // Fetch recipe id + owner user_id (via user_uuid)
    final metaRes = await connection.execute(
      Sql.named(
        'SELECT rd.id, u.id '
        'FROM ${AppConfig.recipeDetails} rd '
        'INNER JOIN ${AppConfig.userDetails} u ON u.uuid = rd.user_uuid '
        'WHERE rd.id = @id '
        'LIMIT 1',
      ),
      parameters: {'id': recipeId},
    );

    if (metaRes.isEmpty) return;

    final int safeRecipeId = (metaRes.first[0] as int?) ?? 0;
    final int ownerUserId = (metaRes.first[1] as int?) ?? 0;
    if (safeRecipeId <= 0 || ownerUserId <= 0) return;

    // Update recipe_details counters (never below 0)
    await connection.execute(
      Sql.named(
        'UPDATE ${AppConfig.recipeDetails} '
        'SET '
        '  views = GREATEST(COALESCE(views, 0) + @views_delta, 0), '
        '  liked_count = GREATEST(COALESCE(liked_count, 0) + @liked_delta, 0), '
        '  bookmarked_count = GREATEST(COALESCE(bookmarked_count, 0) + @bookmark_delta, 0), '
        '  updated_at = NOW() '
        'WHERE id = @id',
      ),
      parameters: {'id': safeRecipeId, 'views_delta': viewsDelta, 'liked_delta': likedDelta, 'bookmark_delta': bookmarkDelta},
    );

    // Update owner user_details aggregates (never below 0)
    await connection.execute(
      Sql.named(
        'UPDATE ${AppConfig.userDetails} '
        'SET '
        '  recipes = GREATEST(COALESCE(recipes, 0) + @recipe_delta, 0), '
        '  views = GREATEST(COALESCE(views, 0) + @views_delta, 0), '
        '  liked = GREATEST(COALESCE(liked, 0) + @liked_delta, 0), '
        '  bookmark = GREATEST(COALESCE(bookmark, 0) + @bookmark_delta, 0), '
        '  updated_at = NOW() '
        'WHERE id = @user_id',
      ),
      parameters: {'user_id': ownerUserId, 'views_delta': viewsDelta, 'liked_delta': likedDelta, 'bookmark_delta': bookmarkDelta, 'recipe_delta': recipeDelta},
    );
  }

  Future<int> deleteRecipeBookmark(int recipeId) async {
    final deleteQuery = ''' DELETE FROM ${AppConfig.recipeBookmark} WHERE recipe_id = @recipe_id''';
    var res = await connection.execute(Sql.named(deleteQuery), parameters: {'recipe_id': recipeId});
    return res.affectedRows;
  }

  Future<int> deleteRecipeWishlist(int recipeId) async {
    final deleteQuery = ''' DELETE FROM ${AppConfig.recipeWishlist} WHERE recipe_id = @recipe_id''';
    var res = await connection.execute(Sql.named(deleteQuery), parameters: {'recipe_id': recipeId});
    return res.affectedRows;
  }

  Future<int> deleteRecipeViews(int recipeId) async {
    final deleteQuery = ''' DELETE FROM ${AppConfig.recipeViews} WHERE recipe_id = @recipe_id''';
    var res = await connection.execute(Sql.named(deleteQuery), parameters: {'recipe_id': recipeId});
    return res.affectedRows;
  }

  Future<Response> toggleRecipeBookmark(String request, int? userId) async {
    final Map<String, dynamic> data = jsonDecode(request);

    final int recipeId = int.parse(data['recipe_id']?.toString() ?? "0");
    final bool isBookmark = parseBool(data['is_bookmarked'], false);

    if (userId == 0 || recipeId == 0) {
      return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_uuid and recipe_uuid required'}));
    }

    // Check if already exists
    final checkQuery = 'SELECT id FROM ${AppConfig.recipeBookmark} WHERE user_id = @user_id AND recipe_id = @recipe_id LIMIT 1';

    final existing = await connection.execute(Sql.named(checkQuery), parameters: {'user_id': userId, 'recipe_id': recipeId});

    if (isBookmark) {
      if (existing.isNotEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already bookmarked'}));
      }

      // Insert new wishlist
      final insertQuery =
          '''
      INSERT INTO ${AppConfig.recipeBookmark}
      (user_id, recipe_id, created_at, updated_at)
      VALUES
      (@user_id, @recipe_id, now(), now())
      RETURNING *
    ''';

      await connection.execute(Sql.named(insertQuery), parameters: {'user_id': userId, 'recipe_id': recipeId});
      // Persist counters (recipe + owner user)
      await _bumpCountersForRecipeUuid(recipeId: recipeId, bookmarkDelta: 1);
      return Response.ok(jsonEncode({'status': 200, 'message': 'Recipe bookmarked'}));
    } else {
      if (existing.isEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already bookmarked'}));
      }

      final deleteQuery =
          '''
      DELETE FROM ${AppConfig.recipeBookmark}
      WHERE user_id = @user_id
        AND recipe_id = @recipe_id
    ''';

      await connection.execute(Sql.named(deleteQuery), parameters: {'user_id': userId, 'recipe_id': recipeId});
      // Persist counters (recipe + owner user)
      await _bumpCountersForRecipeUuid(recipeId: recipeId, bookmarkDelta: -1);
      return Response.ok(jsonEncode({'status': 200, 'message': 'Recipe unbookmarked'}));
    }
  }

  Future<Response> toggleRecipeWishlist(String request, int? userId) async {
    final Map<String, dynamic> data = jsonDecode(request);

    final int recipeId = int.parse(data['recipe_id']?.toString() ?? '0');
    final bool isLike = parseBool(data['is_like'], false);

    if (userId == 0 || recipeId == 0) {
      return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_uuid and recipe_uuid required'}));
    }

    // Check if already exists
    final checkQuery = 'SELECT id FROM ${AppConfig.recipeWishlist} WHERE user_id = @user_id AND recipe_id = @recipe_id LIMIT 1';

    final existing = await connection.execute(Sql.named(checkQuery), parameters: {'user_id': userId, 'recipe_id': recipeId});

    if (isLike) {
      if (existing.isNotEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already liked'}));
      }

      // Insert new wishlist
      final insertQuery =
          '''
      INSERT INTO ${AppConfig.recipeWishlist}
      (user_id, recipe_id, created_at, updated_at)
      VALUES
      (@user_id, @recipe_id, now(), now())
      RETURNING *
    ''';

      await connection.execute(Sql.named(insertQuery), parameters: {'user_id': userId, 'recipe_id': recipeId});
      // Persist counters (recipe + owner user)
      await _bumpCountersForRecipeUuid(recipeId: recipeId, likedDelta: 1);
      return Response.ok(jsonEncode({'status': 200, 'message': 'Recipe liked'}));
    } else {
      if (existing.isEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already unliked'}));
      }

      final deleteQuery =
          '''
      DELETE FROM ${AppConfig.recipeWishlist}
      WHERE user_id = @user_id
        AND recipe_id = @recipe_id
    ''';

      await connection.execute(Sql.named(deleteQuery), parameters: {'user_id': userId, 'recipe_id': recipeId});
      // Persist counters (recipe + owner user)
      await _bumpCountersForRecipeUuid(recipeId: recipeId, likedDelta: -1);
      return Response.ok(jsonEncode({'status': 200, 'message': 'Recipe unliked'}));
    }
  }

  Future<Response> updateRecipeViewList(String request) async {
    final Map<String, dynamic> data = jsonDecode(request);

    final int recipeId = parseInt(data['recipe_id']?.toString());
    final int userId = parseInt(data['user_id']?.toString());

    // Check if view row already exists
    final checkQuery =
        'SELECT id, times FROM ${AppConfig.recipeViews} '
        'WHERE user_id = @user_id AND recipe_id = @recipe_id '
        'LIMIT 1';

    final existing = await connection.execute(Sql.named(checkQuery), parameters: {'user_id': userId, 'recipe_id': recipeId});

    if (existing.isNotEmpty) {
      // If it exists, increment times and revive if deleted
      final updateQuery =
          'UPDATE ${AppConfig.recipeViews} '
          'SET times = COALESCE(times, 0) + 1, updated_at = now() '
          'WHERE user_id = @user_id AND recipe_id = @recipe_id '
          'RETURNING times';

      final res = await connection.execute(Sql.named(updateQuery), parameters: {'user_id': userId, 'recipe_id': recipeId});
      final int newTimes = res.isNotEmpty ? (res.first.first as int) : ((existing.first[1] as int?) ?? 0) + 1;
      await _bumpCountersForRecipeUuid(recipeId: (recipeId), viewsDelta: 1);
      return Response.ok(jsonEncode({'status': 200, 'message': 'View updated', 'times': newTimes}));
    }

    // If it does not exist, insert with times = 1
    final insertQuery =
        '''
      INSERT INTO ${AppConfig.recipeViews}
      (user_id, recipe_id, times, created_at, updated_at)
      VALUES
      (@user_id, @recipe_id, 1, now(), now())
      RETURNING times
    ''';

    final res = await connection.execute(Sql.named(insertQuery), parameters: {'user_id': userId, 'recipe_id': recipeId});

    final int times = res.isNotEmpty ? (res.first.first as int) : 1;
    await _bumpCountersForRecipeUuid(recipeId: recipeId, viewsDelta: 1);
    return Response.ok(jsonEncode({'status': 200, 'message': 'View created', 'times': times}));
  }

  Future<Response> getRecipeViewCountList(String userUuid, int recipeId) async {
    final String query =
        'SELECT rv.times, rv.user_id, rv.recipe_id, u.name AS user_name, rv.created_at, rv.updated_at '
        'FROM ${AppConfig.recipeViews} rv '
        'INNER JOIN ${AppConfig.userDetails} u ON u.id = rv.user_id '
        'WHERE rv.recipe_id = @recipe_id '
        '  AND (u.deleted = false OR u.deleted IS NULL) '
        'ORDER BY rv.times DESC';

    final res = await connection.execute(Sql.named(query), parameters: {'recipe_id': recipeId});

    final resList = DBFunctions.mapFromResultRow(res, ['times', 'user_id', 'recipe_id', 'user_name', 'created_at', 'updated_at']) as List;
    final data = resList
        .map(
          (e) => {
            'times': parseInt(e['times']),
            'user_id'.snakeToCamel: (e['user_id'] ?? '').toString(),
            'recipe_id'.snakeToCamel: (e['recipe_id'] ?? '').toString(),
            'user_name'.snakeToCamel: (e['user_name'] ?? '').toString(),
            'created_at'.snakeToCamel: (e['created_at'] ?? '').toString(),
            'updated_at'.snakeToCamel: (e['updated_at'] ?? '').toString(),
          },
        )
        .toList();

    return Response.ok(jsonEncode({'status': 200, 'data': data}));
  }

  Future<Response> getRecipeLikeCountList(String userUuid, int recipeId) async {
    final String query =
        'SELECT rw.user_id, rw.recipe_id, u.name AS user_name, rw.created_at, rw.updated_at '
        'FROM ${AppConfig.recipeWishlist} rw '
        'INNER JOIN ${AppConfig.userDetails} u ON u.id = rw.user_id '
        'WHERE rw.recipe_id = @recipe_id '
        '  AND (u.deleted = false OR u.deleted IS NULL) '
        'ORDER BY rw.updated_at DESC';

    final res = await connection.execute(Sql.named(query), parameters: {'recipe_id': recipeId});

    final resList = DBFunctions.mapFromResultRow(res, ['user_id', 'recipe_id', 'user_name', 'created_at', 'updated_at']) as List;
    final data = resList
        .map(
          (e) => {
            'user_id'.snakeToCamel: (e['user_id'] ?? '').toString(),
            'recipe_id'.snakeToCamel: (e['recipe_id'] ?? '').toString(),
            'user_name'.snakeToCamel: (e['user_name'] ?? '').toString(),
            'created_at'.snakeToCamel: (e['created_at'] ?? '').toString(),
            'updated_at'.snakeToCamel: (e['updated_at'] ?? '').toString(),
          },
        )
        .toList();

    return Response.ok(jsonEncode({'status': 200, 'data': data}));
  }

  Future<Response> getRecipeBookmarkCountList(String userUuid, int recipeId) async {
    final String query =
        'SELECT rb.user_id, rb.recipe_id, u.name AS user_name, rb.created_at, rb.updated_at '
        'FROM ${AppConfig.recipeBookmark} rb '
        'INNER JOIN ${AppConfig.userDetails} u ON u.id = rb.user_id '
        'WHERE rb.recipe_id = @recipe_id '
        '  AND (u.deleted = false OR u.deleted IS NULL) '
        'ORDER BY rb.updated_at DESC';

    final res = await connection.execute(Sql.named(query), parameters: {'recipe_id': recipeId});

    final resList = DBFunctions.mapFromResultRow(res, ['user_id', 'recipe_id', 'user_name', 'created_at', 'updated_at']) as List;
    final data = resList
        .map(
          (e) => {
            'user_id'.snakeToCamel: (e['user_id'] ?? '').toString(),
            'recipe_id'.snakeToCamel: (e['recipe_id'] ?? '').toString(),
            'user_name'.snakeToCamel: (e['user_name'] ?? '').toString(),
            'created_at'.snakeToCamel: (e['created_at'] ?? '').toString(),
            'updated_at'.snakeToCamel: (e['updated_at'] ?? '').toString(),
          },
        )
        .toList();

    return Response.ok(jsonEncode({'status': 200, 'data': data}));
  }

  Future<Response> getDashboardDataForUser(String userUuid, int userId) async {
    final query =
        '''
      SELECT
        COALESCE(recipes, 0)   AS recipes,
        COALESCE(liked, 0)     AS liked,
        COALESCE(bookmark, 0)  AS bookmark,
        COALESCE(views, 0)     AS views,
        COALESCE(followers, 0) AS followers
      FROM ${AppConfig.userDetails}
      WHERE uuid = @user_uuid
      LIMIT 1;
    ''';

    final res = await connection.execute(Sql.named(query), parameters: {'user_uuid': userUuid});

    final recipes = (res.isNotEmpty ? ((res.first[0] as int?) ?? 0) : 0);
    final liked = (res.isNotEmpty ? ((res.first[1] as int?) ?? 0) : 0);
    final bookmark = (res.isNotEmpty ? ((res.first[2] as int?) ?? 0) : 0);
    final views = (res.isNotEmpty ? ((res.first[3] as int?) ?? 0) : 0);
    final followers = (res.isNotEmpty ? ((res.first[4] as int?) ?? 0) : 0);

    return Response.ok(jsonEncode({'recipes': recipes, 'liked': liked, 'bookmark': bookmark, 'views': views, 'followers': followers}));
  }

  ///UPDATE RECIPE
  ///
  ///
  Future<Response> updateRecipe(String request, String? userUuid, int? userId) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    RecipeEntity? recipeEntity = RecipeEntity.fromJson(requestData);
    RecipeEntity? oldRecipe = await getRecipeFromUuid(recipeEntity.uuid, null, userId: userId);
    if (oldRecipe == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Recipe not found with uuid ${recipeEntity.uuid}'};
      return Response(200, body: jsonEncode(response));
    }
    recipeEntity = await updateRecipeFn(oldRecipe, recipeEntity);
    response['status'] = 200;
    response['message'] = 'Recipe updated successfully';
    response['data'] = recipeEntity?.toJson;
    return Response(201, body: jsonEncode(response));
  }

  ///CREATE RECIPE
  ///
  /// Also creates pricing row in `recipe_pricing` when provided.
  Future<RecipeEntity?> createNewRecipe(RecipeEntity recipe, {Map<String, dynamic>? pricing}) async {
    final insertQuery = DBFunctions.generateInsertQueryFromClass(AppConfig.recipeDetails, recipe.toTableJson);

    final query = insertQuery['query'] as String;
    final params = insertQuery['params'] as List<dynamic>;

    final res = await connection.execute(Sql.named(query), parameters: params);
    final resList = DBFunctions.mapFromResultRow(res, keys) as List;

    if (resList.isEmpty) return null;

    final recipeModel = RecipeEntity.fromJson(resList.first);

    // ✅ Create pricing (optional)
    if (pricing != null) {
      final String accessTier = (pricing['access_tier'] ?? 'FREE').toString().trim().toUpperCase();
      final int price = parseInt(pricing['price']);
      final String currency = (pricing['currency'] ?? 'INR').toString().trim().toUpperCase();

      // If accessTier == PAID then price must be > 0 else keep FREE and price = 0
      final String finalTier = (accessTier == 'PAID' && price <= 0) ? 'FREE' : accessTier;
      final int finalPrice = (finalTier == 'PAID') ? price : 0;
      final pricingInsert = Sql.named(
        'INSERT INTO ${AppConfig.recipePricing} '
        '(recipe_id, access_tier, price, currency, active, deleted, created_at, updated_at, uuid) '
        'VALUES (@recipe_id, @access_tier, @price, @currency, true, false, now(), now(), @uuid)',
      );

      await connection.execute(pricingInsert, parameters: {'recipe_id': recipeModel.id, 'access_tier': finalTier, 'price': finalPrice, 'currency': currency, 'uuid': const Uuid().v8()});
    }

    // Enrich category names
    final List<String> categoryList = await CategoryController.category.getCategoryNameListFromUuidList(recipeModel.categoryUuids ?? []);
    recipeModel.categoryName = categoryList;

    return recipeModel;
  }

  ///UPDATE RECIPE
  ///
  ///
  ///
  Future<RecipeEntity?> updateRecipeFn(RecipeEntity oldRecipe, RecipeEntity recipeEntity) async {
    var updateQuery = DBFunctions.generateSmartUpdate(
      table: AppConfig.recipeDetails,
      oldData: oldRecipe.toTableJson,
      newData: recipeEntity.toTableJson,
      // These are counters/flags derived from other tables or tracked separately.
      // Never allow client update calls to overwrite them.
      ignoreParameters: ['recipe_image_urls', 'views', 'is_bookmarked', 'is_liked', 'liked_count', 'bookmarked_count'],
    );
    final query = updateQuery['query'] as String;
    final params = updateQuery['params'] as List<dynamic>;
    DBFunctions.printSqlWithParams(query, params);
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      var recipeModel = RecipeEntity.fromJson(resList.first);
      List<String> categoryList = await CategoryController.category.getCategoryNameListFromUuidList(recipeModel.categoryUuids ?? []);
      recipeModel.categoryName = categoryList;
      return recipeModel;
    }
    return null;
  }

  ///UPLOAD RECIPE IMAGES (multiple)
  ///
  /// Content-Type: multipart/form-data
  /// Form-data key: images (you can send multiple files with the same key)
  /// Example: images: file1.jpg, images: file2.jpg
  ///
  /// It will append new image paths to existing `recipe_image_urls` in the recipe row.
  Future<Response> uploadRecipeImages(Request request, String recipeUuid, int? userId) async {
    Map<String, dynamic> response = {'status': 400};
    var recipeResponse = await getRecipeFromUuid(recipeUuid, null, liveUrl: false, userId: userId);
    if (recipeResponse == null) {
      response['status'] = 404;
      response['message'] = 'Recipe not found with uuid $recipeUuid';
      return Response(200, body: jsonEncode(response));
    }
    List<String> existingImages = recipeResponse.recipeImageUrls ?? [];
    var multipartResponse = await DBFunctions.multipartImageConfigure(request, 'recipe/$recipeUuid', recipeUuid, startIndex: existingImages.length);
    if (multipartResponse is Response) {
      return multipartResponse;
    }
    if (multipartResponse is String) {
      existingImages.add(multipartResponse);
    } else {
      List<String> imagePaths = multipartResponse as List<String>;
      if (imagePaths.isEmpty) {
        response['message'] = 'No images found in the request';
        return Response.badRequest(body: jsonEncode(response));
      }
      existingImages.addAll(imagePaths);
    }
    //Update recipe image Urls
    final conditionData = DBFunctions.buildConditions({'uuid': recipeUuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.recipeDetails} SET recipe_image_urls = \'${existingImages.map((e) => jsonEncode(e)).toList()}\' WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    if (res.affectedRows > 0) {
      response['status'] = 200;
      response['message'] = 'Recipe images updated successfully';
      response['data'] = existingImages.map((e) => BaseRepository.buildFileUrl(e)).toList();
      return Response(200, body: jsonEncode(response));
    } else {
      response['status'] = 400;
      response['message'] = 'Failed to update recipe images';
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<Response> deleteRecipeImages(String recipeUuid, String imageIndex, int? userId) async {
    Map<String, dynamic> response = {'status': 400};
    var recipeResponse = await getRecipeFromUuid(recipeUuid, null, liveUrl: false, userId: userId);
    if (recipeResponse == null) {
      response['status'] = 404;
      response['message'] = 'Recipe not found with uuid $recipeUuid';
      return Response(404, body: jsonEncode(response));
    }
    List<String> existingImages = recipeResponse.recipeImageUrls ?? [];
    existingImages = existingImages.map((e) => e.replaceAll('uploads/', '')).toList();
    String? file = existingImages.where((e) => e.contains('${recipeUuid}_$imageIndex')).firstOrNull;
    file = '${AppConfig.uploadsDir}$file';
    if (!File(file).existsSync()) {
      response['status'] = 404;
      response['message'] = 'Recipe not found with image index $imageIndex';
      return Response(404, body: jsonEncode(response));
    }
    await File(file).delete();
    existingImages.remove(file);
    //Update recipe image Urls
    final conditionData = DBFunctions.buildConditions({'uuid': recipeUuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.recipeDetails} SET recipe_image_urls = \'${existingImages.map((e) => jsonEncode(e)).toList()}\' WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    if (res.affectedRows > 0) {
      response['status'] = 200;
      response['message'] = 'Recipe image deleted successfully';
      return Response(200, body: jsonEncode(response));
    } else {
      response['status'] = 400;
      response['message'] = 'Failed to delete recipe images';
      return Response(400, body: jsonEncode(response));
    }
  }

  /// Convenience wrapper if you want the same response signature style
  Future<Response> uploadRecipeImagesResponse(Request request, String recipeUuid, int? userId) async {
    return uploadRecipeImages(request, recipeUuid, userId);
  }

  ///DELETE CATEGORY
  ///
  ///
  ///
  Future<Response> deleteRecipeFromUuidResponse(String uuid, int? userId) async {
    var recipeResponse = await getRecipeFromUuid(uuid, null, userId: userId);
    if (recipeResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Recipe not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      int deletedRecipeBookmarks = await deleteRecipeBookmark(recipeResponse.id);
      int deletedRecipeLikes = await deleteRecipeWishlist(recipeResponse.id);
      int deletedRecipeViews = await deleteRecipeViews(recipeResponse.id);
      await _bumpCountersForRecipeUuid(
        recipeId: recipeResponse.id,
        viewsDelta: deletedRecipeViews * -1,
        likedDelta: deletedRecipeLikes * -1,
        bookmarkDelta: deletedRecipeBookmarks * -1,
        recipeDelta: -1,
      );
      for (String images in recipeResponse.recipeImageUrls ?? []) {
        await deleteRecipeImages(uuid, (images.split('${uuid}_').last).split('.').first, userId);
      }
      await deleteRecipeFromUuid(uuid);
      Map<String, dynamic> response = {'status': 200, 'message': 'Recipe deleted successfully'};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<List<dynamic>> deleteRecipeFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.recipeDetails} SET deleted = true, active = false WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    return DBFunctions.mapFromResultRow(res, keys);
  }

  ///DEACTIVATE CATEGORY
  ///
  ///
  ///
  Future<Response> deactivateRecipeFromUuidResponse(String uuid, bool active, int? userId) async {
    var recipeResponse = await getRecipeFromUuid(uuid, null, userId: userId);
    if (recipeResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Recipe not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      if (recipeResponse.active == active) {
        Map<String, dynamic> response = {'status': 404, 'message': 'Recipe already ${active ? 'Active' : 'De-Active'}'};
        return Response(200, body: jsonEncode(response));
      }
      await deactivateRecipeFromUuid(uuid, active);
      Map<String, dynamic> response = {'status': 200, 'message': 'Recipe status changed successfully'};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<List<dynamic>> deactivateRecipeFromUuid(String uuid, bool active) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.recipeDetails} SET active = $active WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    return DBFunctions.mapFromResultRow(res, keys);
  }
}
