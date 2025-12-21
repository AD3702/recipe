import 'dart:convert';

import 'package:recipe/controller/auth_controller.dart';
import 'package:recipe/controller/user_controller.dart';
import 'package:recipe/repositories/auth/contract/auth_repository.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/utils/string_extension.dart';

import 'package:shelf/shelf.dart';

class AuthApiRepository implements AuthRepository {
  AuthController authController = AuthController.auth;

  @override
  Future<Response> authRootHandler(Request req) async {
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
        case BaseRepository.login:
          String requestBody = (await req.readAsString()).convertJsonCamelToSnake;
          response = await authController.login(requestBody);
          break;
        case BaseRepository.updateToken:
          response = await authController.updateToken(req.headers['authorization'] ?? '');
          break;
        case BaseRepository.generateOtp:
          String requestBody = (await req.readAsString()).convertJsonCamelToSnake;
          response = await authController.generateOtp(requestBody);
          break;
        case BaseRepository.forgotPassword:
          String requestBody = (await req.readAsString()).convertJsonCamelToSnake;
          response = await authController.generateOtp(requestBody);
          break;
        case BaseRepository.resetPassword:
          String requestBody = (await req.readAsString()).convertJsonCamelToSnake;
          response = await authController.resetPassword(requestBody);
          break;
        case BaseRepository.verifyOtp:
          String requestBody = (await req.readAsString()).convertJsonCamelToSnake;
          response = (await authController.verifyOtp(requestBody)).$1;
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
