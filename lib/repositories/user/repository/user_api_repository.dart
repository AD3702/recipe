import 'dart:convert';

import 'package:recipe/controller/user_controller.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/user/contract/user_repository.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:shelf/shelf.dart';

class UserApiRepository implements UserRepository {
  UserController userController = UserController.user;

  @override
  Future<Response> userRootHandler(Request req) async {
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
      final mergedHeaders = {...response.headers, 'Content-Type': 'application/json'};
      response = response.change(headers: mergedHeaders);
      return response;
    }
    Map<String, dynamic> tokenMap = jsonDecode(await response.readAsString());
    String? userUuid = tokenMap['uuid']?.toString();
    int? userId = int.tryParse(tokenMap['userId']?.toString() ?? '');
    try {
      switch (requestPath) {
        case BaseRepository.user:
          if (req.method == RequestType.GET.name || req.method == RequestType.PUT.name) {
            String? uuid = queryParam['uuid'];
            if (uuid == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await userController.getUserFromUuidResponse(uuid, userId);
            }
          } else {
            response = await userController.addUser((await req.readAsString()).convertJsonCamelToSnake);
          }
          break;

        case BaseRepository.profile:
          response = await userController.getUserProfile(userUuid ?? '');
          break;
        case BaseRepository.cookApproval:
          int? id = int.tryParse(queryParam['id'] ?? '');
          bool? isAdminApprovedRequest = bool.tryParse(queryParam['isAdminApprovedRequest'] ?? '');
          response = await userController.updateUserAdminApproval(id ?? 0, isAdminApprovedRequest ?? false);
          break;
        case BaseRepository.superAdminDashboard:
          response = await userController.getSuperAdminDashboard();
          break;
        case BaseRepository.userDocuments:
          response = await userController.uploadCookVerificationDocumentFormData(req, userId ?? 0);
          break;
        case BaseRepository.userProfileImage:
          response = await userController.uploadUserProfileImage(req, userId ?? 0);
          break;
        case BaseRepository.userDelete:
          String? uuid = queryParam['uuid'];
          if (uuid == null) {
            Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
            response = Response.badRequest(body: jsonEncode(res));
          } else {
            response = await userController.deleteUserFromUuidResponse(uuid);
          }
          break;
        case BaseRepository.userStatus:
          String? uuid = queryParam['uuid'];
          bool? active = bool.tryParse(queryParam['active']);
          if (uuid == null || active == null) {
            Map<String, dynamic> res = {'status': 400, 'message': 'UUID or Status is missing from request param'};
            response = Response.badRequest(body: jsonEncode(res));
          } else {
            response = await userController.deactivateUserFromUuidResponse(uuid, active);
          }
          break;
        case BaseRepository.userList:
          String requestBody = (await req.readAsString()).convertJsonCamelToSnake;
          response = await userController.getUserListResponse(jsonDecode(requestBody), userUuid ?? '', userId ?? 0);
          break;
        case BaseRepository.toggleFollowing:
          if (req.method == RequestType.PUT.name) {
            response = await userController.toggleUserFollowing((await req.readAsString()).convertJsonCamelToSnake, userId ?? 0);
          }
          break;
        default:
          response = Response(404);
          break;
      }
    } catch (e, st) {
      print(st);
      response = Response.badRequest();
    }
    final mergedHeaders = {...response.headers, 'Content-Type': 'application/json'};
    response = response.change(headers: mergedHeaders);
    return response;
  }
}
