import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:postgres/postgres.dart';
import 'package:recipe/annotations/need_login.dart'; // <-- add
import 'package:recipe/repositories/user/model/user_entity.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/string_extension.dart';
import 'package:shelf/shelf.dart';

class BaseRepository {
  BaseRepository._();

  static BaseRepository baseRepository = BaseRepository._();

  late Connection connection;

  static final Map<String, Map<RequestType, List<Object>>> routeAnnotations = {
    login: {RequestType.POST: []},
    generateOtp: {RequestType.POST: []},
    verifyOtp: {RequestType.POST: []},
    forgotPassword: {RequestType.POST: []},
    resetPassword: {RequestType.POST: []},
    updateToken: {
      RequestType.GET: const <Object>[NeedLogin(adminOnly: true)],
    },
    user: {
      RequestType.GET: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    userDelete: {
      RequestType.DELETE: const <Object>[NeedLogin(adminOnly: true)],
    },
    userStatus: {
      RequestType.PUT: const <Object>[NeedLogin(adminOnly: true)],
    },
    userList: {
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    category: {
      RequestType.GET: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    categoryDelete: {
      RequestType.DELETE: const <Object>[NeedLogin(adminOnly: true)],
    },
    categoryStatus: {
      RequestType.PUT: const <Object>[NeedLogin(adminOnly: true)],
    },
    categoryList: {
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    attribute: {
      RequestType.GET: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    attributeDelete: {
      RequestType.DELETE: const <Object>[NeedLogin(adminOnly: true)],
    },
    attributeStatus: {
      RequestType.PUT: const <Object>[NeedLogin(adminOnly: true)],
    },
    attributeList: {
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    recipe: {
      RequestType.GET: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    recipeDelete: {
      RequestType.DELETE: const <Object>[NeedLogin(adminOnly: true)],
    },
    recipeStatus: {
      RequestType.PUT: const <Object>[NeedLogin(adminOnly: true)],
    },
    recipeList: {
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
  };

  // -------------------------------------------------------

  Response baseRootHandler(Request req) {
    final requestPath = req.requestedUri.path;
    final method = req.method;

    if (!RequestMapper.isPathValid(requestPath)) {
      return Response(404);
    }
    if (!RequestMapper.isRequestTypeValid(requestPath, method)) {
      return Response(405);
    }

    final reqType = _toRequestType(method);
    final annotation = routeAnnotations[requestPath]?[reqType] ?? const <Object>[];

    NeedLogin? needLogin;
    for (final a in annotation) {
      if (a is NeedLogin) {
        needLogin = a;
        break;
      }
    }

    String? payloadJson;

    if (needLogin != null) {
      final authHeader = req.headers['Authorization'];
      if (authHeader == null) {
        return Response.unauthorized(jsonEncode({'status': 401, 'message': 'Authorization token is missing'}));
      }

      payloadJson = BaseRepository.baseRepository.verifyToken(authHeader);
      if (payloadJson == null) {
        return Response.unauthorized(jsonEncode({'status': 401, 'message': 'Unauthorized'}));
      }

      final payloadMap = jsonDecode(payloadJson) as Map<String, dynamic>;
      if (!needLogin.hasAccess(payloadMap)) {
        return Response.forbidden(jsonEncode({'status': 403, 'message': 'Admin access required'}));
      }
    }

    return Response(200, body: payloadJson ?? '');
  }

  String generateJwtToken(String userName, UserType userType) {
    final jwt = JWT({'userName': userName.encryptBasic, 'userType': userType.name.encryptBasic}, issuer: AppConfig.appName.encryptBasic);
    final token = jwt.sign(SecretKey(AppConfig.secretKey), expiresIn: Duration(days: 1));
    return token;
  }

  String? verifyToken(String token) {
    try {
      final jwt = JWT.verify(token, SecretKey(AppConfig.secretKey), checkExpiresIn: true);
      return jsonEncode(jwt.payload);
    } catch (ex) {
      print('Error: $ex');
      return null;
    }
  }

  static const String auth = '/auth';
  static const String login = '/auth/login';
  static const String updateToken = '/auth/refresh/token';
  static const String generateOtp = '/auth/generate/otp';
  static const String verifyOtp = '/auth/verify/otp';
  static const String forgotPassword = '/auth/forgot/password';
  static const String resetPassword = '/auth/reset/password';
  static const String user = '/user';
  static const String userDelete = '/user/delete';
  static const String userList = '/user/list';
  static const String userStatus = '/user/status';
  static const String category = '/category';
  static const String categoryDelete = '/category/delete';
  static const String categoryList = '/category/list';
  static const String categoryStatus = '/category/status';
  static const String attribute = '/attribute';
  static const String attributeDelete = '/attribute/delete';
  static const String attributeList = '/attribute/list';
  static const String attributeStatus = '/attribute/status';
  static const String recipe = '/recipe';
  static const String recipeDelete = '/recipe/delete';
  static const String recipeList = '/recipe/list';
  static const String recipeStatus = '/recipe/status';

  // Helper
  RequestType _toRequestType(String method) {
    for (final e in RequestType.values) {
      if (e.name == method) return e;
    }
    return RequestType.GET;
  }
}

class RequestMapper {
  RequestMapper._();

  static bool isPathValid(String request) {
    return BaseRepository.routeAnnotations[request] != null;
  }

  static bool isRequestTypeValid(String request, String requestType) {
    return BaseRepository.routeAnnotations[request]?.keys.map((e) => e.name).toList().contains(requestType) ?? false;
  }
}

enum RequestType { GET, POST, PUT, PATCH, DELETE }
