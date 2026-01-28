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
    String? userUuid = tokenMap['uuid']?.toString();
    int? userId = int.tryParse(tokenMap['userId']?.toString() ?? '');
    try {
      switch (requestPath) {
        case BaseRepository.recipe:
          if (req.method == RequestType.GET.name) {
            String? uuid = queryParam['uuid'];
            if (uuid == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await recipeController.getRecipeFromUuidResponse(uuid, userUuid, userId);
            }
          } else if (req.method == RequestType.PUT.name) {
            response = await recipeController.updateRecipe((await req.readAsString()).convertJsonCamelToSnake, userUuid, userId);
          } else {
            response = await recipeController.addRecipe((await req.readAsString()).convertJsonCamelToSnake, userUuid, userId);
          }
          break;
        case BaseRepository.toggleRecipeWishlist:
          if (req.method == RequestType.PUT.name) {
            response = await recipeController.toggleRecipeWishlist((await req.readAsString()).convertJsonCamelToSnake, userId ?? 0);
          }
          if (req.method == RequestType.GET.name) {
            int? recipeId = int.tryParse(queryParam['recipeId'] ?? '');
            if (recipeId == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'ID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await recipeController.getRecipeLikeCountList(userUuid ?? '', recipeId!);
            }
          }
          break;
        case BaseRepository.dashboard:
          if (req.method == RequestType.GET.name) {
            response = await recipeController.getDashboardDataForUser(userUuid ?? '', userId ?? 0);
          }
          break;
        case BaseRepository.toggleRecipeBookmark:
          if (req.method == RequestType.PUT.name) {
            response = await recipeController.toggleRecipeBookmark((await req.readAsString()).convertJsonCamelToSnake, userId ?? 0);
          }
          if (req.method == RequestType.GET.name) {
            int? recipeId = int.tryParse(queryParam['recipeId'] ?? '');
            if (recipeId == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'ID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await recipeController.getRecipeBookmarkCountList(userUuid ?? '', recipeId!);
            }
          }
          break;
        case BaseRepository.recipeView:
          if (req.method == RequestType.PUT.name) {
            response = await recipeController.updateRecipeViewList((await req.readAsString()).convertJsonCamelToSnake);
          } else if (req.method == RequestType.GET.name) {
            int? recipeId = int.tryParse(queryParam['recipeId'] ?? '');
            if (recipeId == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'ID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await recipeController.getRecipeViewCountList(userUuid ?? '', recipeId!);
            }
          }
          break;
        case BaseRepository.recipeImage:
          String? uuid = queryParam['uuid'];
          if (uuid == null) {
            Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
            response = Response.badRequest(body: jsonEncode(res));
          } else {
            if (req.method == RequestType.PUT.name) {
              response = await recipeController.uploadRecipeImagesResponse(req, uuid, userId);
            } else if (req.method == RequestType.DELETE.name) {
              String? imageIndex = queryParam['imageIndex'];
              if (imageIndex == null) {
                Map<String, dynamic> res = {'status': 400, 'message': 'Image index is missing from request param'};
                response = Response.badRequest(body: jsonEncode(res));
              } else {
                response = await recipeController.deleteRecipeImages(uuid, imageIndex, userId);
              }
            }
          }
          break;
        case BaseRepository.recipeDelete:
          if (req.method == RequestType.DELETE.name) {
            String? uuid = queryParam['uuid'];
            if (uuid == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await recipeController.deleteRecipeFromUuidResponse(uuid, userId);
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
            response = await recipeController.deactivateRecipeFromUuidResponse(uuid, active, userId);
          }
          break;
        case BaseRepository.recipeList:
          String requestBody = (await req.readAsString()).convertJsonCamelToSnake;
          response = await recipeController.getRecipeListResponse(jsonDecode(requestBody), userUuid, userId);
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
