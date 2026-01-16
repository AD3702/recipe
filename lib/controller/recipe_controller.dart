import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:recipe/controller/category_controller.dart';
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

  ///GET CATEGORY LIST
  ///
  ///
  ///
  Future<(List<RecipeEntity>, PaginationEntity)> getRecipeList(Map<String, dynamic> requestBody, String? userUuid) async {
    int? pageSize = int.tryParse(requestBody['page_size'].toString());
    int? pageNumber = int.tryParse(requestBody['page_number'].toString());
    bool isShuffled = bool.tryParse(requestBody['is_shuffled'].toString()) ?? false;
    bool isBookmarkedOnly = bool.tryParse(requestBody['is_bookmarked'].toString()) ?? false;

    // Remove custom flags before building base conditions
    requestBody.remove('is_shuffled');
    requestBody.remove('is_bookmarked');

    final conditionData = DBFunctions.buildConditions(requestBody, searchKeys: ['name'], limit: pageSize, offset: (pageNumber != null && pageSize != null) ? (pageNumber - 1) * pageSize : null);

    final conditions = (conditionData['conditions'] as List<String>);
    final suffix = (conditionData['suffix'] as String);
    final params = (conditionData['params'] as List<dynamic>);
    final suffixParams = (conditionData['suffixParams'] as List<dynamic>);

    // Seeded shuffle (stable pagination) when is_shuffled=true
    final String viewerKey = (requestBody['viewer_uuid'] ?? requestBody['viewer_id'] ?? requestBody['user_uuid'] ?? requestBody['session_id'] ?? '').toString();
    final int windowMinutes = int.tryParse((requestBody['shuffle_window_minutes'] ?? 10).toString()) ?? 10;
    final int windowMs = windowMinutes * 60 * 1000;
    final int windowBucket = DateTime.now().millisecondsSinceEpoch ~/ windowMs;
    final String derivedSeed = '${viewerKey.trim()}::$windowBucket';
    final String shuffleSeed = (requestBody['shuffle_seed'] ?? derivedSeed).toString();
    final safeSeed = shuffleSeed.replaceAll("'", "''");

    // Build LIKE/BOOKMARK clauses only when userUuid is present
    final bool canPersonalize = userUuid != null && userUuid.trim().isNotEmpty;
    final String safeUserUuid = (userUuid ?? '').replaceAll("'", "''");

    final String likedSelect = canPersonalize
        ? "EXISTS(SELECT 1 FROM ${AppConfig.recipeWishlist} wl WHERE wl.recipe_uuid = rd.uuid AND wl.user_uuid = '$safeUserUuid' AND wl.deleted = false) AS is_liked"
        : 'false AS is_liked';

    final String bookmarkedSelect = canPersonalize
        ? "EXISTS(SELECT 1 FROM ${AppConfig.recipeBookmark} bm WHERE bm.recipe_uuid = rd.uuid AND bm.user_uuid = '$safeUserUuid' AND bm.deleted = false) AS is_bookmarked"
        : 'false AS is_bookmarked';

    // If client requests bookmarked-only feed, apply it via EXISTS (no extra pre-query / IN list)
    final String bookmarkedWhere = (isBookmarkedOnly && canPersonalize)
        ? " AND EXISTS(SELECT 1 FROM ${AppConfig.recipeBookmark} bm2 WHERE bm2.recipe_uuid = rd.uuid AND bm2.user_uuid = '$safeUserUuid' AND bm2.deleted = false)"
        : '';

    final String viewsSelect = 'COALESCE((SELECT SUM(COALESCE(rv.times, 0)) FROM ${AppConfig.recipeViews} rv WHERE rv.recipe_uuid = rd.uuid AND rv.deleted = false), 0) AS views';
    final String likedCountSelect = 'COALESCE((SELECT COUNT(*) FROM ${AppConfig.recipeWishlist} wl2 WHERE wl2.recipe_uuid = rd.uuid AND wl2.deleted = false), 0) AS liked_count';
    final String bookmarkedCountSelect = 'COALESCE((SELECT COUNT(*) FROM ${AppConfig.recipeBookmark} bm2 WHERE bm2.recipe_uuid = rd.uuid AND bm2.deleted = false), 0) AS bookmarked_count';

    // Stable shuffle order (only affects ordering)
    final String orderClause = isShuffled ? " ORDER BY md5(COALESCE(rd.uuid::text, '') || '$safeSeed')" : '';

    final selectKeys = keys.map((k) => 'rd.$k').join(',');
    final extraKeys = ['is_liked', 'is_bookmarked', 'views', 'liked_count', 'bookmarked_count'];

    // Prefix recipe_details columns with alias `rd.` inside generated conditions
    final whereSql = conditions.map((c) => c.replaceAllMapped(RegExp(r'\b(uuid|id|active|deleted|created_at|updated_at|user_uuid|name)\b'), (m) => 'rd.${m[0]}')).join(' AND ');

    final query =
        'SELECT $selectKeys, $likedSelect, $bookmarkedSelect, $viewsSelect, $likedCountSelect, $bookmarkedCountSelect '
        'FROM ${AppConfig.recipeDetails} rd '
        'WHERE $whereSql'
        '$bookmarkedWhere'
        '$orderClause '
        '$suffix';

    final countQuery =
        'SELECT COUNT(*) '
        'FROM ${AppConfig.recipeDetails} rd '
        'WHERE $whereSql'
        '$bookmarkedWhere';

    final res = await connection.execute(Sql.named(query), parameters: params + suffixParams);

    final countRes = await connection.execute(Sql.named(countQuery), parameters: params);

    int totalCount = countRes.first.first as int;
    PaginationEntity paginationEntity = PaginationEntity(totalCount: totalCount, pageSize: pageSize ?? totalCount, pageNumber: pageNumber ?? 1);

    // Map results including computed flags
    final mapped = DBFunctions.mapFromResultRow(res, [...keys, ...extraKeys]) as List;

    final List<RecipeEntity> recipeList = [];
    for (final row in mapped) {
      final recipeModel = RecipeEntity.fromJson(row);

      // computed booleans
      recipeModel.isLiked = parseBool(row['is_liked'], false);
      recipeModel.isBookmarked = parseBool(row['is_bookmarked'], false);
      recipeModel.views = parseInt(row['views']);
      recipeModel.likedCount = parseInt(row['liked_count']);
      recipeModel.bookmarkedCount = parseInt(row['bookmarked_count']);

      // existing enrichment (kept as-is)
      recipeModel.recipeImageUrls = recipeModel.recipeImageUrls?.map((e) => BaseRepository.buildFileUrl(e)).toList() ?? [];
      recipeModel.categoryName = await CategoryController.category.getCategoryNameListFromUuidList(recipeModel.categoryUuids ?? []);
      recipeModel.userName = (await UserController.user.getUserFromUuid(recipeModel.userUuid ?? ''))?.name ?? '';

      recipeList.add(recipeModel);
    }

    return (recipeList, paginationEntity);
  }

  Future<RecipeEntity?> getRecipeFromUuid(String uuid, String? userUuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final bool canPersonalize = userUuid != null && userUuid.trim().isNotEmpty;
    final String safeUserUuid = (userUuid ?? '').replaceAll("'", "''");

    final String likedSelect = canPersonalize
        ? "EXISTS(SELECT 1 FROM ${AppConfig.recipeWishlist} wl WHERE wl.recipe_uuid = rd.uuid AND wl.user_uuid = '$safeUserUuid' AND wl.deleted = false) AS is_liked"
        : 'false AS is_liked';

    final String bookmarkedSelect = canPersonalize
        ? "EXISTS(SELECT 1 FROM ${AppConfig.recipeBookmark} bm WHERE bm.recipe_uuid = rd.uuid AND bm.user_uuid = '$safeUserUuid' AND bm.deleted = false) AS is_bookmarked"
        : 'false AS is_bookmarked';

    final String viewsSelect = 'COALESCE((SELECT SUM(COALESCE(rv.times, 0)) FROM ${AppConfig.recipeViews} rv WHERE rv.recipe_uuid = rd.uuid AND rv.deleted = false), 0) AS views';
    final String likedCountSelect = 'COALESCE((SELECT COUNT(*) FROM ${AppConfig.recipeWishlist} wl2 WHERE wl2.recipe_uuid = rd.uuid AND wl2.deleted = false), 0) AS liked_count';
    final String bookmarkedCountSelect = 'COALESCE((SELECT COUNT(*) FROM ${AppConfig.recipeBookmark} bm2 WHERE bm2.recipe_uuid = rd.uuid AND bm2.deleted = false), 0) AS bookmarked_count';

    final selectKeys = keys.map((k) => 'rd.$k').join(',');

    final whereSql = conditions.map((c) => c.replaceAllMapped(RegExp(r'\buuid\b'), (m) => 'rd.uuid')).join(' AND ');

    final query =
        'SELECT $selectKeys, $likedSelect, $bookmarkedSelect, $viewsSelect, $likedCountSelect, $bookmarkedCountSelect '
        'FROM ${AppConfig.recipeDetails} rd '
        'WHERE $whereSql '
        'LIMIT 1';

    final res = await connection.execute(Sql.named(query), parameters: params);

    final mapped = DBFunctions.mapFromResultRow(res, [...keys, 'is_liked', 'is_bookmarked', 'views', 'liked_count', 'bookmarked_count']) as List;

    if (mapped.isNotEmpty) {
      final row = mapped.first;
      var recipeModel = RecipeEntity.fromJson(row);

      recipeModel.isLiked = parseBool(row['is_liked'], false);
      recipeModel.isBookmarked = parseBool(row['is_bookmarked'], false);
      recipeModel.views = parseInt(row['views']);
      recipeModel.likedCount = parseInt(row['liked_count']);
      recipeModel.bookmarkedCount = parseInt(row['bookmarked_count']);

      recipeModel.recipeImageUrls = recipeModel.recipeImageUrls?.map((e) => BaseRepository.buildFileUrl(e)).toList() ?? [];
      recipeModel.userName = (await UserController.user.getUserFromUuid(recipeModel.userUuid ?? ''))?.name ?? '';
      recipeModel.categoryName = await CategoryController.category.getCategoryNameListFromUuidList(recipeModel.categoryUuids ?? []);

      return recipeModel;
    }

    return null;
  }

  Future<Response> getRecipeListResponse(Map<String, dynamic> requestBody, String? userUuid) async {
    var recipeList = await getRecipeList(requestBody, userUuid);
    Map<String, dynamic> response = {'status': 200, 'message': 'Recipe list found successfully'};
    response['data'] = recipeList.$1.map((e) => e.toJson).toList();
    response['pagination'] = recipeList.$2.toJson;
    return Response(200, body: jsonEncode(response));
  }

  ///GET CATEGORY DETAILS
  ///
  ///
  ///
  Future<Response> getRecipeFromUuidResponse(String uuid, String? userUuid) async {
    var recipeResponse = await getRecipeFromUuid(uuid, userUuid);

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
  Future<Response> addRecipe(String request, String? userUuid) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    List<String> requiredParams = ['name'];
    List<String> requestParams = requestData.keys.toList();
    var res = DBFunctions.checkParamValidRequest(requestParams, requiredParams);
    if (res != null) {
      response['message'] = res;
      return Response.badRequest(body: jsonEncode(response));
    }
    RecipeEntity? recipeEntity = RecipeEntity.fromJson(requestData);
    recipeEntity = await createNewRecipe(recipeEntity);
    response['status'] = 200;
    response['message'] = 'Recipe created successfully';
    response['data'] = recipeEntity?.toJson;
    return Response(201, body: jsonEncode(response));
  }

  Future<Response> toggleRecipeBookmark(String request, String userUuid) async {
    final Map<String, dynamic> data = jsonDecode(request);

    final String recipeUuid = data['recipe_uuid'] ?? '';
    final bool isBookmark = parseBool(data['is_bookmarked'], false);

    if (userUuid.isEmpty || recipeUuid.isEmpty) {
      return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_uuid and recipe_uuid required'}));
    }

    // Check if already exists
    final checkQuery = 'SELECT uuid FROM ${AppConfig.recipeBookmark} WHERE user_uuid = @user_uuid AND recipe_uuid = @recipe_uuid AND deleted = false LIMIT 1';

    final existing = await connection.execute(Sql.named(checkQuery), parameters: {'user_uuid': userUuid, 'recipe_uuid': recipeUuid});

    if (isBookmark) {
      if (existing.isNotEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already bookmarked'}));
      }

      // Insert new wishlist
      final insertQuery =
          '''
      INSERT INTO ${AppConfig.recipeBookmark}
      (uuid, user_uuid, recipe_uuid, active, deleted, created_at, updated_at)
      VALUES
      (@uuid, @user_uuid, @recipe_uuid, true, false, now(), now())
      RETURNING *
    ''';

      await connection.execute(Sql.named(insertQuery), parameters: {'uuid': const Uuid().v8(), 'user_uuid': userUuid, 'recipe_uuid': recipeUuid});
      return Response.ok(jsonEncode({'status': 200, 'message': 'Recipe bookmarked'}));
    } else {
      if (existing.isEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already bookmarked'}));
      }

      final deleteQuery =
          '''
      DELETE FROM ${AppConfig.recipeBookmark}
      WHERE user_uuid = @user_uuid
        AND recipe_uuid = @recipe_uuid
    ''';

      await connection.execute(Sql.named(deleteQuery), parameters: {'user_uuid': userUuid, 'recipe_uuid': recipeUuid});

      return Response.ok(jsonEncode({'status': 200, 'message': 'Recipe bookmarked'}));
    }
  }

  Future<List<String>> getBookMarkRecipeListForUser(String userUuid, {int? pageSize, int? pageNumber}) async {
    final bool hasPagination = pageSize != null && pageSize > 0;
    final int safePageNumber = (pageNumber == null || pageNumber <= 0) ? 1 : pageNumber;
    final int offset = hasPagination ? (safePageNumber - 1) * pageSize! : 0;

    final String query = hasPagination
        ? 'SELECT recipe_uuid FROM ${AppConfig.recipeBookmark} WHERE user_uuid = @user_uuid AND deleted = false ORDER BY created_at DESC LIMIT @limit OFFSET @offset'
        : 'SELECT recipe_uuid FROM ${AppConfig.recipeBookmark} WHERE user_uuid = @user_uuid AND deleted = false ORDER BY created_at DESC';

    final res = await connection.execute(Sql.named(query), parameters: {'user_uuid': userUuid, if (hasPagination) 'limit': pageSize, if (hasPagination) 'offset': offset});

    final resList = DBFunctions.mapFromResultRow(res, ['recipe_uuid']) as List;

    final List<String> recipeUuidList = [];
    for (final row in resList) {
      final v = row['recipe_uuid'];
      if (v == null) continue;
      recipeUuidList.add(v.toString());
    }
    return recipeUuidList;
  }

  Future<Response> getRecipeViewCountList(String userUuid, String recipeUuid) async {
    final String query =
        'SELECT rv.times, rv.user_uuid, rv.recipe_uuid, u.name AS user_name '
        'FROM ${AppConfig.recipeViews} rv '
        'INNER JOIN ${AppConfig.userDetails} u ON u.uuid = rv.user_uuid '
        'WHERE rv.recipe_uuid = @recipe_uuid '
        '  AND rv.deleted = false '
        '  AND (u.deleted = false OR u.deleted IS NULL) '
        'ORDER BY rv.created_at DESC';

    final res = await connection.execute(Sql.named(query), parameters: {'recipe_uuid': recipeUuid});

    final resList = DBFunctions.mapFromResultRow(res, ['times', 'user_uuid', 'recipe_uuid', 'user_name']) as List;
    final data = resList
        .map((e) => {'times': parseInt(e['times']), 'user_uuid'.snakeToCamel: (e['user_uuid'] ?? '').toString(), 'recipe_uuid'.snakeToCamel: (e['recipe_uuid'] ?? '').toString(), 'user_name'.snakeToCamel: (e['user_name'] ?? '').toString()})
        .toList();

    return Response.ok(jsonEncode({'status': 200, 'data': data}));
  }

  Future<Response> getDashboardDataForUser(String userUuid) async {
    final query =
        '''
      SELECT
        (SELECT COUNT(*)
           FROM ${AppConfig.recipeWishlist} wl
           INNER JOIN ${AppConfig.recipeDetails} rd ON rd.uuid = wl.recipe_uuid
          WHERE rd.user_uuid = @user_uuid
            AND wl.deleted = false
        ) AS liked,
        (SELECT COUNT(*)
           FROM ${AppConfig.recipeBookmark} bm
           INNER JOIN ${AppConfig.recipeDetails} rd2 ON rd2.uuid = bm.recipe_uuid
          WHERE rd2.user_uuid = @user_uuid
            AND bm.deleted = false
        ) AS bookmark,
        (SELECT COALESCE(SUM(COALESCE(rv.times, 0)), 0)
           FROM ${AppConfig.recipeViews} rv
           INNER JOIN ${AppConfig.recipeDetails} rd3 ON rd3.uuid = rv.recipe_uuid
          WHERE rd3.user_uuid = @user_uuid
            AND rv.deleted = false
        ) AS views;
    ''';

    final res = await connection.execute(Sql.named(query), parameters: {'user_uuid': userUuid});

    final liked = (res.isNotEmpty ? (res.first[0] as int) : 0);
    final bookmark = (res.isNotEmpty ? (res.first[1] as int) : 0);
    final views = (res.isNotEmpty ? (res.first[2] as int) : 0);

    return Response.ok(jsonEncode({'liked': liked, 'bookmark': bookmark, 'views': views}));
  }

  Future<Response> toggleRecipeWishlist(String request, String userUuid) async {
    final Map<String, dynamic> data = jsonDecode(request);

    final String recipeUuid = data['recipe_uuid'] ?? '';
    final bool isLike = parseBool(data['is_like'], false);

    if (userUuid.isEmpty || recipeUuid.isEmpty) {
      return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_uuid and recipe_uuid required'}));
    }

    // Check if already exists
    final checkQuery = 'SELECT uuid FROM ${AppConfig.recipeWishlist} WHERE user_uuid = @user_uuid AND recipe_uuid = @recipe_uuid AND deleted = false LIMIT 1';

    final existing = await connection.execute(Sql.named(checkQuery), parameters: {'user_uuid': userUuid, 'recipe_uuid': recipeUuid});

    if (isLike) {
      if (existing.isNotEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already liked'}));
      }

      // Insert new wishlist
      final insertQuery =
          '''
      INSERT INTO ${AppConfig.recipeWishlist}
      (uuid, user_uuid, recipe_uuid, active, deleted, created_at, updated_at)
      VALUES
      (@uuid, @user_uuid, @recipe_uuid, true, false, now(), now())
      RETURNING *
    ''';

      await connection.execute(Sql.named(insertQuery), parameters: {'uuid': const Uuid().v8(), 'user_uuid': userUuid, 'recipe_uuid': recipeUuid});
      return Response.ok(jsonEncode({'status': 200, 'message': 'Recipe liked'}));
    } else {
      if (existing.isEmpty) {
        return Response.ok(jsonEncode({'status': 200, 'message': 'Already unliked'}));
      }

      final deleteQuery =
          '''
      DELETE FROM ${AppConfig.recipeWishlist}
      WHERE user_uuid = @user_uuid
        AND recipe_uuid = @recipe_uuid
    ''';

      await connection.execute(Sql.named(deleteQuery), parameters: {'user_uuid': userUuid, 'recipe_uuid': recipeUuid});

      return Response.ok(jsonEncode({'status': 200, 'message': 'Recipe unliked'}));
    }
  }

  Future<Response> updateRecipeViewList(String request) async {
    final Map<String, dynamic> data = jsonDecode(request);

    final String recipeUuid = data['recipe_uuid'] ?? '';
    final String userUuid = data['user_uuid'] ?? '';

    if (userUuid.isEmpty || recipeUuid.isEmpty) {
      return Response.badRequest(body: jsonEncode({'status': 400, 'message': 'user_uuid and recipe_uuid required'}));
    }

    // Check if view row already exists
    final checkQuery =
        'SELECT uuid, times, deleted FROM ${AppConfig.recipeViews} '
        'WHERE user_uuid = @user_uuid AND recipe_uuid = @recipe_uuid '
        'LIMIT 1';

    final existing = await connection.execute(Sql.named(checkQuery), parameters: {'user_uuid': userUuid, 'recipe_uuid': recipeUuid});

    if (existing.isNotEmpty) {
      // If it exists, increment times and revive if deleted
      final updateQuery =
          'UPDATE ${AppConfig.recipeViews} '
          'SET times = COALESCE(times, 0) + 1, updated_at = now(), deleted = false, active = true '
          'WHERE user_uuid = @user_uuid AND recipe_uuid = @recipe_uuid '
          'RETURNING times';

      final res = await connection.execute(Sql.named(updateQuery), parameters: {'user_uuid': userUuid, 'recipe_uuid': recipeUuid});

      final int newTimes = res.isNotEmpty ? (res.first.first as int) : ((existing.first[1] as int?) ?? 0) + 1;
      return Response.ok(jsonEncode({'status': 200, 'message': 'View updated', 'times': newTimes}));
    }

    // If it does not exist, insert with times = 1
    final insertQuery =
        '''
      INSERT INTO ${AppConfig.recipeViews}
      (uuid, user_uuid, recipe_uuid, times, active, deleted, created_at, updated_at)
      VALUES
      (@uuid, @user_uuid, @recipe_uuid, 1, true, false, now(), now())
      RETURNING times
    ''';

    final res = await connection.execute(Sql.named(insertQuery), parameters: {'uuid': const Uuid().v8(), 'user_uuid': userUuid, 'recipe_uuid': recipeUuid});

    final int times = res.isNotEmpty ? (res.first.first as int) : 1;
    return Response.ok(jsonEncode({'status': 200, 'message': 'View created', 'times': times}));
  }

  ///UPDATE RECIPE
  ///
  ///
  Future<Response> updateRecipe(String request, String? userUuid) async {
    Map<String, dynamic> requestData = jsonDecode(request);
    Map<String, dynamic> response = {'status': 400};
    RecipeEntity? recipeEntity = RecipeEntity.fromJson(requestData);
    RecipeEntity? oldRecipe = await getRecipeFromUuid(recipeEntity.uuid, null);
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

  ///CREATE CATEGORY
  ///
  ///
  ///
  Future<RecipeEntity?> createNewRecipe(RecipeEntity recipe) async {
    var insertQuery = DBFunctions.generateInsertQueryFromClass(AppConfig.recipeDetails, recipe.toTableJson);
    print(insertQuery);
    print(insertQuery['params']);
    final query = insertQuery['query'] as String;
    final params = insertQuery['params'] as List<dynamic>;
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

  ///UPDATE RECIPE
  ///
  ///
  ///
  Future<RecipeEntity?> updateRecipeFn(RecipeEntity oldRecipe, RecipeEntity recipeEntity) async {
    var updateQuery = DBFunctions.generateSmartUpdate(table: AppConfig.recipeDetails, oldData: oldRecipe.toTableJson, newData: recipeEntity.toTableJson, ignoreParameters: ['recipe_image_urls']);
    final query = updateQuery['query'] as String;
    final params = updateQuery['params'] as List<dynamic>;
    print(query);
    print(params);
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
  Future<Response> uploadRecipeImages(Request request, String recipeUuid) async {
    Map<String, dynamic> response = {'status': 400};
    var recipeResponse = await getRecipeFromUuid(recipeUuid, null);
    if (recipeResponse == null) {
      response['status'] = 404;
      response['message'] = 'Recipe not found with uuid $recipeUuid';
      return Response(200, body: jsonEncode(response));
    }
    List<String> existingImages = recipeResponse.recipeImageUrls ?? [];
    for (var path in existingImages) {
      if (File(path).existsSync()) {
        File(path).delete();
      }
    }
    var multipartResponse = await DBFunctions.multipartImageConfigure(request, 'recipe/$recipeUuid', recipeUuid);
    if (multipartResponse is Response) {
      return multipartResponse;
    }
    List<String> imagePaths = multipartResponse as List<String>;
    if (imagePaths.isEmpty) {
      response['message'] = 'No images found in the request';
      return Response.badRequest(body: jsonEncode(response));
    }
    //Update recipe image Urls
    final conditionData = DBFunctions.buildConditions({'uuid': recipeUuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'UPDATE ${AppConfig.recipeDetails} SET recipe_image_urls = \'${imagePaths.map((e) => jsonEncode(e)).toList()}\' WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    if (res.affectedRows > 0) {
      response['status'] = 200;
      response['message'] = 'Recipe images updated successfully';
      return Response(200, body: jsonEncode(response));
    } else {
      response['status'] = 400;
      response['message'] = 'Failed to update recipe images';
      return Response(200, body: jsonEncode(response));
    }
  }

  /// Convenience wrapper if you want the same response signature style
  Future<Response> uploadRecipeImagesResponse(Request request, String recipeUuid) async {
    return uploadRecipeImages(request, recipeUuid);
  }

  ///DELETE CATEGORY
  ///
  ///
  ///
  Future<Response> deleteRecipeFromUuidResponse(String uuid) async {
    var recipeResponse = await getRecipeFromUuid(uuid, null);
    if (recipeResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Recipe not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
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
  Future<Response> deactivateRecipeFromUuidResponse(String uuid, bool active) async {
    var recipeResponse = await getRecipeFromUuid(uuid, null);
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
