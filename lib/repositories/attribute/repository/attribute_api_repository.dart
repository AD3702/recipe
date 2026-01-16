import 'dart:convert';

import 'package:recipe/controller/attribute_controller.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/repositories/attribute/contract/attribute_repository.dart';
import 'package:recipe/utils/string_extension.dart';

import 'package:shelf/shelf.dart';

class AttributeApiRepository implements AttributeRepository {
  AttributeController attributeController = AttributeController.attribute;

  @override
  Future<Response> attributeRootHandler(Request req) async {
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
    try {
      switch (requestPath) {
        case BaseRepository.attribute:
          if (req.method == RequestType.GET.name || req.method == RequestType.PUT.name) {
            String? uuid = queryParam['uuid'];
            if (uuid == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await attributeController.getAttributeFromUuidResponse(uuid);
            }
          } else {
            response = await attributeController.addAttribute((await req.readAsString()).convertJsonCamelToSnake);
          }
          break;
        case BaseRepository.attributeDelete:
          if (req.method == RequestType.DELETE.name) {
            String? uuid = queryParam['uuid'];
            if (uuid == null) {
              Map<String, dynamic> res = {'status': 400, 'message': 'UUID is missing from request param'};
              response = Response.badRequest(body: jsonEncode(res));
            } else {
              response = await attributeController.deleteAttributeFromUuidResponse(uuid);
            }
          } else {
            response = Response(200);
          }
          break;
        case BaseRepository.attributeStatus:
          String? uuid = queryParam['uuid'];
          bool? active = bool.tryParse(queryParam['active']);
          if (uuid == null || active == null) {
            Map<String, dynamic> res = {'status': 400, 'message': 'UUID or Status is missing from request param'};
            response = Response.badRequest(body: jsonEncode(res));
          } else {
            response = await attributeController.deactivateAttributeFromUuidResponse(uuid, active);
          }
          break;
        case BaseRepository.attributeList:
          String requestBody = (await req.readAsString()).convertJsonCamelToSnake;
          response = await attributeController.getAttributeListResponse(jsonDecode(requestBody));
          break;
        default:
          response = Response(404, body: jsonEncode({'message': 'Not found'}));
          break;
      }
    } catch (e) {
      response = Response.badRequest();
    }
    final mergedHeaders = {...response.headers, 'Content-Type': 'application/json'};
    response = response.change(headers: mergedHeaders);

    return response;
  }
}
