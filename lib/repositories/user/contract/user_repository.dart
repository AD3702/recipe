import 'package:shelf/shelf.dart';

abstract class UserRepository {
  Future<Response> userRootHandler(Request req);
}
