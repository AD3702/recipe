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
    register: {RequestType.POST: []},
    generateOtp: {RequestType.POST: []},
    verifyOtp: {RequestType.POST: []},
    forgotPassword: {RequestType.POST: []},
    resetPassword: {RequestType.POST: []},
    profile: {
      RequestType.GET: const <Object>[NeedLogin()],
    },
    updateToken: {
      RequestType.GET: const <Object>[NeedLogin(adminOnly: true)],
    },
    user: {
      RequestType.GET: const <Object>[NeedLogin()],
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    userDocuments: {
      RequestType.PUT: const <Object>[NeedLogin()],
    },
    userDelete: {
      RequestType.DELETE: const <Object>[NeedLogin(adminOnly: true)],
    },
    userStatus: {
      RequestType.PUT: const <Object>[NeedLogin(adminOnly: true)],
    },
    userList: {
      RequestType.POST: const <Object>[NeedLogin()],
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
    categoryList: {RequestType.POST: []},
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
    cookApproval: {
      RequestType.PUT: const <Object>[NeedLogin(adminOnly: true)],
    },
    attributeList: {
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    recipe: {
      RequestType.GET: const <Object>[],
      RequestType.POST: const <Object>[NeedLogin()],
      RequestType.PUT: const <Object>[NeedLogin()],
    },
    recipeImage: {
      RequestType.PUT: const <Object>[NeedLogin()],
      RequestType.DELETE: const <Object>[NeedLogin()],
    },
    dashboard: {
      RequestType.GET: const <Object>[NeedLogin()],
    },
    superAdminDashboard: {
      RequestType.GET: const <Object>[NeedLogin(adminOnly: true)],
    },
    toggleRecipeWishlist: {
      RequestType.PUT: const <Object>[NeedLogin()],
      RequestType.GET: const <Object>[NeedLogin()],
    },
    toggleFollowing: {
      RequestType.PUT: const <Object>[NeedLogin()],
      RequestType.GET: const <Object>[NeedLogin()],
    },
    toggleRecipeBookmark: {
      RequestType.PUT: const <Object>[NeedLogin()],
      RequestType.GET: const <Object>[NeedLogin()],
    },
    recipeDelete: {
      RequestType.DELETE: const <Object>[NeedLogin()],
    },
    recipeStatus: {
      RequestType.PUT: const <Object>[NeedLogin()],
    },
    recipeList: {RequestType.POST: []},
    recipeView: {
      RequestType.PUT: [],
      RequestType.GET: <Object>[NeedLogin()],
    },

    // ---------------- Payments ----------------
    paymentsPlans: {
      RequestType.GET: const <Object>[],
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.PUT: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.DELETE: const <Object>[NeedLogin(adminOnly: true)],
    },
    paymentsSubscriptions: {
      RequestType.GET: const <Object>[NeedLogin()],
      RequestType.POST: const <Object>[NeedLogin()],
      RequestType.PUT: const <Object>[NeedLogin()],
      RequestType.DELETE: const <Object>[NeedLogin(adminOnly: true)],
    },
    paymentsRecipePricing: {
      RequestType.GET: const <Object>[],
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.PUT: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.DELETE: const <Object>[NeedLogin(adminOnly: true)],
    },
    paymentsRecipePurchases: {
      RequestType.GET: const <Object>[NeedLogin()],
      RequestType.POST: const <Object>[NeedLogin()],
    },
    paymentsMonthlyRecipeMetrics: {
      RequestType.GET: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    paymentsMonthlySubscriptionRevenue: {
      RequestType.GET: const <Object>[NeedLogin(adminOnly: true)],
      RequestType.POST: const <Object>[NeedLogin(adminOnly: true)],
    },
    paymentsCookMonthlyEarnings: {
      RequestType.GET: const <Object>[NeedLogin()],
    },
    paymentsCookWalletTransactions: {
      RequestType.GET: const <Object>[NeedLogin()],
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
    Map<String, dynamic> payloadMap = {};

    final authHeader = req.headers['Authorization'];
    if (authHeader == null && needLogin != null) {
      return Response.unauthorized(jsonEncode({'status': 401, 'message': 'Authorization token is missing'}));
    }

    payloadJson = BaseRepository.baseRepository.verifyToken(authHeader ?? '''{}''');

    if (payloadJson == null && needLogin != null) {
      return Response.unauthorized(jsonEncode({'status': 401, 'message': 'Unauthorized'}));
    }

    payloadMap = (jsonDecode(payloadJson ?? '''{}''') as Map<String, dynamic>).map((key, value) {
      if (key == 'userName' || key == 'userType' || key == 'iss' || key == 'userId' || key == 'uuid') {
        return MapEntry(key, (value as String).decryptBasic);
      }
      return MapEntry(key, value);
    });

    if (!(needLogin?.hasAccess(payloadMap) ?? true)) {
      return Response.forbidden(jsonEncode({'status': 403, 'message': 'Admin access required'}));
    }

    return Response(200, body: jsonEncode(payloadMap));
  }

  String generateJwtToken({
    required int userId,
    required String userName,
    required UserType userType,
    required String uuid,
    required String contact,
    required DateTime createdAt,
    required String password,
  }) {
    final jwt = JWT({
      'userId': userId.toString().encryptBasic,
      'userType': userType.name.encryptBasic,
      'uuid': uuid.encryptBasic,
      'contact': contact.encryptBasic,
      'createdAt': createdAt.toIso8601String().encryptBasic,
      'password': password.encryptBasic,
    }, issuer: AppConfig.appName.encryptBasic);
    final token = jwt.sign(SecretKey(AppConfig.secretKey), expiresIn: Duration(days: 365));
    return token;
  }

  String? verifyToken(String token) {
    try {
      final jwt = JWT.verify(token, SecretKey(AppConfig.secretKey), checkExpiresIn: true);
      return jsonEncode(jwt.payload);
    } catch (ex) {
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
  static const String register = '/auth/register';
  static const String user = '/user';
  static const String toggleFollowing = '/user/following';
  static const String profile = '/user/profile';
  static const String cookApproval = '/user/cook_approval';
  static const String superAdminDashboard = '/user/dashboard';
  static const String userDocuments = '/user/documents';
  static const String userProfileImage = '/user/profile/image';
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
  static const String payments = '/payments';
  static const String toggleRecipeWishlist = '/recipe/like';
  static const String toggleRecipeBookmark = '/recipe/bookmark';
  static const String recipeDelete = '/recipe/delete';
  static const String recipeImage = '/recipe/image';
  static const String recipeList = '/recipe/list';
  static const String recipeStatus = '/recipe/status';
  static const String dashboard = '/recipe/dashboard';
  static const String recipeView = '/recipe/view';
  static const String paymentsSubscriptions = '/payments/user_subscriptions';

  // ---------------- Payments Routes ----------------
  static const String paymentsPlans = '/payments/subscription_plans';
  static const String paymentsRecipePricing = '/payments/recipe_pricing';
  static const String paymentsRecipePurchases = '/payments/recipe_purchases';
  static const String paymentsMonthlyRecipeMetrics = '/payments/monthly_recipe_metrics';
  static const String paymentsMonthlySubscriptionRevenue = '/payments/monthly_subscription_revenue';
  static const String paymentsCookMonthlyEarnings = '/payments/cook_monthly_earnings';
  static const String paymentsCookWalletTransactions = '/payments/cook_wallet_transactions';

  static String buildFileUrl(String? filePath) {
    if (filePath == null || filePath.isEmpty) return '';
    filePath = filePath.replaceAll('uploads', '');

    // Ensure forward slashes for Windows/macOS/Linux
    final normalized = filePath.replaceAll('\\', '/');

    // Remove any leading slashes
    final cleanPath = normalized.startsWith('/') ? normalized.substring(1) : normalized;

    // Example:
    // AppConfig.baseUrl = "https://api.yourdomain.com"
    // returns:
    // https://api.yourdomain.com/uploads/cook_verification/xxx.jpg
    if (AppConfig.publicBaseUrl != null) {
      return '${AppConfig.publicBaseUrl}/uploads/$cleanPath';
    } else {
      return '${'${AppConfig.baseUrl}:${AppConfig.serverPort}'}/uploads/$cleanPath';
    }
  }

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
