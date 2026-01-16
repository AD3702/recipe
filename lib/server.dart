import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:recipe/controller/attribute_controller.dart';
import 'package:recipe/controller/category_controller.dart';
import 'package:recipe/controller/recipe_controller.dart';
import 'package:recipe/controller/user_controller.dart';
import 'package:recipe/repositories/attribute/contract/attribute_repository.dart';
import 'package:recipe/repositories/attribute/model/attribute_entity.dart';
import 'package:recipe/repositories/attribute/repository/attribute_api_repository.dart';
import 'package:recipe/repositories/auth/contract/auth_repository.dart';
import 'package:recipe/repositories/auth/model/generate_otp.dart';
import 'package:recipe/repositories/auth/repository/auth_api_repository.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/base/repository/otp_cleanup_timer.dart';
import 'package:recipe/repositories/category/contract/category_repository.dart';
import 'package:recipe/repositories/category/model/category_entity.dart';
import 'package:recipe/repositories/category/repository/category_api_repository.dart';
import 'package:recipe/repositories/recipe/contract/recipe_repository.dart';
import 'package:recipe/repositories/recipe/model/recipe_bookmark_table.dart';
import 'package:recipe/repositories/recipe/model/recipe_entity.dart';
import 'package:recipe/repositories/recipe/model/recipe_views_table.dart';
import 'package:recipe/repositories/recipe/model/recipe_wishlist_table.dart';
import 'package:recipe/repositories/recipe/repository/recipe_api_repository.dart';
import 'package:recipe/repositories/user/contract/user_repository.dart';
import 'package:recipe/repositories/user/model/user_documents_model.dart';
import 'package:recipe/repositories/user/model/user_entity.dart';
import 'package:recipe/repositories/user/repository/user_api_repository.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

// CORS
const Map<String, String> _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS',
  'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization, X-Requested-With',
  'Access-Control-Max-Age': '86400',
};

Middleware _corsMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      // Handle preflight request
      if (request.method.toUpperCase() == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }

      final response = await innerHandler(request);
      return response.change(headers: _corsHeaders);
    };
  };
}

final _router = Router();

void configureRoutes(Router router) {
  UserRepository userRepository = UserApiRepository();
  AuthRepository authRepository = AuthApiRepository();
  CategoryRepository categoryRepository = CategoryApiRepository();
  AttributeRepository attributeRepository = AttributeApiRepository();
  RecipeRepository recipeRepository = RecipeApiRepository();
  // ✅ serve /uploads/* from local folder "uploads/"
  router.mount('/uploads/', createStaticHandler('uploads', serveFilesOutsidePath: true));
  router.mount(BaseRepository.user, userRepository.userRootHandler);
  router.mount(BaseRepository.auth, authRepository.authRootHandler);
  router.mount(BaseRepository.category, categoryRepository.categoryRootHandler);
  router.mount(BaseRepository.attribute, attributeRepository.attributeRootHandler);
  router.mount(BaseRepository.recipe, recipeRepository.recipeRootHandler);
}

void main(List<String> args) async {
  BaseRepository.baseRepository.connection = await Connection.open(
    Endpoint(host: AppConfig.dbHost, port: AppConfig.dbPort, database: AppConfig.dbName, username: AppConfig.dbUser, password: AppConfig.dbPassword),
    settings: ConnectionSettings(sslMode: SslMode.disable),
  );

  // Configure routes
  configureRoutes(_router);

  final ip = InternetAddress.anyIPv4;
  print('Starting server on http://${ip.address}:${AppConfig.serverPort}');
  final handler = Pipeline().addMiddleware(_corsMiddleware()).addMiddleware(logRequests()).addHandler(_router.call);
  final port = AppConfig.serverPort;
  await DBFunctions.createTableFromClass(BaseRepository.baseRepository.connection, AppConfig.userDetails, UserEntity().toTableJson);
  await DBFunctions.createTableFromClass(BaseRepository.baseRepository.connection, AppConfig.generateOtp, GenerateOtp().toTableJson);
  await DBFunctions.createTableFromClass(BaseRepository.baseRepository.connection, AppConfig.categoryDetails, CategoryEntity().toTableJson);
  await DBFunctions.createTableFromClass(BaseRepository.baseRepository.connection, AppConfig.attributeDetails, AttributeEntity().toTableJson);
  await DBFunctions.createTableFromClass(BaseRepository.baseRepository.connection, AppConfig.recipeDetails, RecipeEntity().toTableJson);
  await DBFunctions.createTableFromClass(BaseRepository.baseRepository.connection, AppConfig.cookVerificationDocuments, UserDocumentsModel().toTableJson);
  await DBFunctions.createTableFromClass(BaseRepository.baseRepository.connection, AppConfig.recipeWishlist, RecipeWishlist().toTableJson);
  await DBFunctions.createTableFromClass(BaseRepository.baseRepository.connection, AppConfig.recipeBookmark, RecipeBookmarkList().toTableJson);
  await DBFunctions.createTableFromClass(BaseRepository.baseRepository.connection, AppConfig.recipeViews, RecipeViewsList().toTableJson);
  await UserController.user.createSuperAdmin();
  await CategoryController.category.insertNewCategoryList();
  await AttributeController.attribute.insertNewAttributeList();
  final server = await serve(handler, ip, port);
  OtpCleanupScheduler.start();
  print('Server listening on port ${server.port}');

  ProcessSignal.sigint.watch().listen((_) async {
    await BaseRepository.baseRepository.connection.close();
    print('Database connection closed');
  });
}
