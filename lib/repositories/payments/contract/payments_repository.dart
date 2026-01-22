import 'package:shelf/shelf.dart';

abstract class PaymentsRepository {
  Future<Response> paymentsRootHandler(Request req);
}
