import 'package:shelf/shelf.dart';

abstract class AttributeRepository {
  Future<Response> attributeRootHandler(Request req);
}
