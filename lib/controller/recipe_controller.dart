import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:recipe/repositories/base/model/pagination_entity.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/recipe/model/recipe_entity.dart';
import 'package:recipe/repositories/recipe/model/recipe_entity.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:shelf/shelf.dart';

class RecipeController {
  late Connection connection;

  RecipeController._() {
    connection = BaseRepository.baseRepository.connection;
  }

  static RecipeController recipe = RecipeController._();
  final keys = RecipeEntity().toTableJson.keys.toList();

  ///GET CATEGORY LIST
  ///
  ///
  ///
  Future<(List<RecipeEntity>, PaginationEntity)> getRecipeList(Map<String, dynamic> requestBody) async {
    int? pageSize = int.tryParse(requestBody['page_size'].toString());
    int? pageNumber = int.tryParse(requestBody['page_number'].toString());
    final conditionData = DBFunctions.buildConditions(
      requestBody,
      searchKeys: ['name'],
      limit: pageSize,
      offset: (pageNumber != null && pageSize != null) ? (pageNumber - 1) * pageSize : null,
    );

    final conditions = conditionData['conditions'] as List<String>;
    final suffix = conditionData['suffix'] as String;
    final params = conditionData['params'] as List<dynamic>;
    final suffixParams = conditionData['suffixParams'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.recipeDetails} WHERE ${conditions.join(' AND ')} $suffix';
    final countQuery = 'SELECT COUNT(*) FROM ${AppConfig.recipeDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params + suffixParams);
    final countRes = await connection.execute(Sql.named(countQuery), parameters: params);
    int totalCount = countRes.first.first as int;
    PaginationEntity paginationEntity = PaginationEntity(totalCount: totalCount, pageSize: pageSize ?? totalCount, pageNumber: pageNumber ?? 1);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;

    List<RecipeEntity> recipeList = [];
    for (var recipe in resList) {
      recipeList.add(RecipeEntity.fromJson(recipe));
    }
    return (recipeList, paginationEntity);
  }

  Future<Response> getRecipeListResponse(Map<String, dynamic> requestBody) async {
    var recipeList = await getRecipeList(requestBody);
    Map<String, dynamic> response = {'status': 200, 'message': 'Recipe list found successfully'};
    response['data'] = recipeList.$1.map((e) => e.toJson).toList();
    response['pagination'] = recipeList.$2.toJson;
    return Response(200, body: jsonEncode(response));
  }

  ///GET CATEGORY DETAILS
  ///
  ///
  ///
  Future<Response> getRecipeFromUuidResponse(String uuid) async {
    var recipeResponse = await getRecipeFromUuid(uuid);

    if (recipeResponse == null) {
      Map<String, dynamic> response = {'status': 404, 'message': 'Recipe not found with uuid $uuid'};
      return Response(200, body: jsonEncode(response));
    } else {
      Map<String, dynamic> response = {'status': 200, 'message': 'Recipe found', 'data': recipeResponse.toJson};
      return Response(200, body: jsonEncode(response));
    }
  }

  Future<RecipeEntity?> getRecipeFromUuid(String uuid) async {
    final conditionData = DBFunctions.buildConditions({'uuid': uuid});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;
    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.recipeDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return RecipeEntity.fromJson(resList.first);
    }
    return null;
  }

  Future<RecipeEntity?> getRecipeFromName(String name) async {
    final conditionData = DBFunctions.buildConditions({'name': name});
    final conditions = conditionData['conditions'] as List<String>;
    final params = conditionData['params'] as List<dynamic>;

    final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.recipeDetails} WHERE ${conditions.join(' AND ')}';
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return RecipeEntity.fromJson(resList.first);
    }
    return null;
  }

  ///ADD CATEGORY
  ///
  ///
  Future<Response> addRecipe(String request) async {
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
    // RecipeEntity? recipeWithName = await getRecipeFromName(recipeEntity.name ?? '');
    // if (recipeWithName != null) {
    //   response['message'] = 'Recipe with name already exists';
    //   return Response.badRequest(body: jsonEncode(response));
    // }
    recipeEntity = await createNewRecipe(recipeEntity);
    response['status'] = 200;
    response['message'] = 'Recipe created successfully';
    return Response(201, body: jsonEncode(response));
  }

  ///CREATE CATEGORY
  ///
  ///
  ///
  Future<RecipeEntity?> createNewRecipe(RecipeEntity recipe) async {
    var insertQuery = DBFunctions.generateInsertQueryFromClass(AppConfig.recipeDetails, recipe.toTableJson);
    final query = insertQuery['query'] as String;
    final params = insertQuery['params'] as List<dynamic>;
    final res = await connection.execute(Sql.named(query), parameters: params);
    var resList = DBFunctions.mapFromResultRow(res, keys) as List;
    if (resList.isNotEmpty) {
      return RecipeEntity.fromJson(resList.first);
    }
    return null;
  }

  ///DELETE CATEGORY
  ///
  ///
  ///
  Future<Response> deleteRecipeFromUuidResponse(String uuid) async {
    print(uuid);
    var recipeResponse = await getRecipeFromUuid(uuid);
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
    print(uuid);
    var recipeResponse = await getRecipeFromUuid(uuid);
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
