import 'dart:convert';

import 'package:recipe/controller/payments_controller.dart';
import 'package:recipe/controller/recipe_controller.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/payments/contract/payments_repository.dart';
import 'package:recipe/repositories/recipe/contract/recipe_repository.dart';

import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';
import 'package:uuid/uuid.dart';
import 'package:recipe/utils/string_extension.dart';

import 'package:shelf/shelf.dart';

class PaymentsApiRepository implements PaymentsRepository {
  PaymentsController paymentsController = PaymentsController.payments;

  @override
  Future<Response> paymentsRootHandler(Request req) async {
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
    Map<String, dynamic> tokenMap = jsonDecode(await response.readAsString());
    String? userUuid = tokenMap['uuid']?.toString();
    int? userId = int.tryParse(tokenMap['userId']?.toString() ?? '');
    try {
      switch (requestPath) {
        case BaseRepository.paymentsPlans:
          if (req.method == RequestType.GET.name) {
            String? userType = queryParam['userType'];
            response = await paymentsController.getSubscriptionPlansList(userType);
          }
          break;
        case BaseRepository.paymentsSubscriptions:
          if (req.method == RequestType.POST.name) {
            response = await paymentsController.upsertUserSubscription(jsonDecode(await req.readAsString()));
          }
          break;
      }
    } catch (e, st) {
      print(e);
      print(st);
      response = Response.badRequest(body: jsonEncode({'message': 'Bad request'}));
    }
    final mergedHeaders = {...response.headers, 'Content-Type': 'application/json'};
    response = response.change(headers: mergedHeaders);
    return response;
  }
}
