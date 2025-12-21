import 'dart:convert';

import 'package:recipe/controller/recipe_controller.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/recipe/contract/recipe_repository.dart';
import 'package:recipe/repositories/recipe/contract/recipe_repository.dart';
import 'package:recipe/utils/string_extension.dart';

import 'package:shelf/shelf.dart';

class RecipeApiRepository implements RecipeRepository {
  RecipeController recipeController = RecipeController.recipe;

  @override
  Future<Response> recipeRootHandler(Request req) async {
    Response response = Response(400);
    String requestPath = req.requestedUri.path;
    var param = req.url.hasQuery ? req.url.query : null;
    Map<String, dynamic> queryParam = {};
    if (param != null) {
      param.split('&').forEach((element) {
        queryParam[element.split('=').first] = element.split('=').last;
      });
    }
    response = BaseRepository.baseRepository.baseRootHandler(req);
    if (response.statusCode != 200) {
      response = response.change(headers: {...response.headers, 'Content-Type': 'application/json'});
      return response;
    }
    try {
      switch (requestPath) {
        case BaseRepository.recipe:
          if (req.method == RequestType.GET.name || req.method == RequestType.PUT.name) {
            String? uuid = queryParam['uuid'];
            if (uuid == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await recipeController.getRecipeFromUuidResponse(uuid);
            }
          } else {
            response = await recipeController.addRecipe((await req.readAsString()).convertJsonCamelToSnake);
          }
          break;
        case BaseRepository.recipeDelete:
          if (req.method == RequestType.DELETE.name) {
            String? uuid = queryParam['uuid'];
            if (uuid == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await recipeController.deleteRecipeFromUuidResponse(uuid);
            }
          } else {
            response = Response(200);
          }
          break;
        case BaseRepository.recipeStatus:
          String? uuid = queryParam['uuid'];
          bool? active = bool.tryParse(queryParam['active']);
          if (uuid == null || active == null) {
            Map<String, dynamic> res = {'status': 400, 'message': 'UUID or Status is missing from request param'};
            response = Response.badRequest(body: jsonEncode(res));
          } else {
            response = await recipeController.deactivateRecipeFromUuidResponse(uuid, active);
          }
          break;
        case BaseRepository.recipeList:
          String requestBody = (await req.readAsString()).convertJsonCamelToSnake;
          response = await recipeController.getRecipeListResponse(jsonDecode(requestBody));
          break;
        default:
          response = Response(404, body: jsonEncode({'message': 'Not found'}));
          break;
      }
    } catch (e) {
      print(e);
      response = Response.badRequest();
    }
    final mergedHeaders = {...response.headers, 'Content-Type': 'application/json'};
    response = response.change(headers: mergedHeaders);
    print(response.headers);
    return response;
  }
}
