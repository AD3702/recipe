import 'package:shelf/shelf.dart';

abstract class RecipeRepository {
  Future<Response> recipeRootHandler(Request req);
}
