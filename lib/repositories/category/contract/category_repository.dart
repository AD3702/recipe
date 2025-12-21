import 'package:shelf/shelf.dart';

abstract class CategoryRepository {
  Future<Response> categoryRootHandler(Request req);
}
