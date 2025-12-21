import 'package:shelf/shelf.dart';

abstract class AuthRepository {
  Future<Response> authRootHandler(Request req);
}
