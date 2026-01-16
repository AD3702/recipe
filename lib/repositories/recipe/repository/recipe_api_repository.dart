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
    Map<String, dynamic> tokenMap = jsonDecode(await response.readAsString());
    String? userUuid = tokenMap['uuid'];
    try {
      switch (requestPath) {
        case BaseRepository.recipe:
          if (req.method == RequestType.GET.name) {
            String? uuid = queryParam['uuid'];
            if (uuid == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await recipeController.getRecipeFromUuidResponse(uuid, userUuid);
            }
          } else if (req.method == RequestType.PUT.name) {
            response = await recipeController.updateRecipe((await req.readAsString()).convertJsonCamelToSnake, userUuid);
          } else {
            response = await recipeController.addRecipe((await req.readAsString()).convertJsonCamelToSnake, userUuid);
          }
          break;
        case BaseRepository.toggleRecipeWishlist:
          if (req.method == RequestType.PUT.name) {
            response = await recipeController.toggleRecipeWishlist((await req.readAsString()).convertJsonCamelToSnake, userUuid ?? '');
          }
          break;
        case BaseRepository.dashboard:
          if (req.method == RequestType.GET.name) {
            response = await recipeController.getDashboardDataForUser(userUuid ?? '');
          }
          break;
        case BaseRepository.toggleRecipeBookmark:
          if (req.method == RequestType.PUT.name) {
            response = await recipeController.toggleRecipeBookmark((await req.readAsString()).convertJsonCamelToSnake, userUuid ?? '');
          }
          break;
        case BaseRepository.recipeView:
          if (req.method == RequestType.PUT.name) {
            response = await recipeController.updateRecipeViewList((await req.readAsString()).convertJsonCamelToSnake);
          } else if (req.method == RequestType.GET.name) {
            String? recipeUuid = queryParam['recipeUuid'];
            if (recipeUuid == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await recipeController.getRecipeViewCountList(userUuid ?? '', recipeUuid!);
            }
          }
          break;
        case BaseRepository.recipeImage:
          String? uuid = queryParam['uuid'];
          if (uuid == null) {
            Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
            response = Response.badRequest(body: jsonEncode(res));
          } else {
            response = await recipeController.uploadRecipeImagesResponse(req, uuid);
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
          response = await recipeController.getRecipeListResponse(jsonDecode(requestBody), userUuid);
          break;
        default:
          response = Response(404, body: jsonEncode({'message': 'Not found'}));
          break;
      }
    } catch (e, st) {
      print(e);
      print(st);
      response = Response.badRequest();
    }
    final mergedHeaders = {...response.headers, 'Content-Type': 'application/json'};
    response = response.change(headers: mergedHeaders);

    return response;
  }
}
