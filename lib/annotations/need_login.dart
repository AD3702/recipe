import 'package:recipe/repositories/user/model/user_entity.dart';
import 'package:recipe/utils/string_extension.dart';

class NeedLogin {
  /// When true, only admin users can access.
  final bool adminOnly;

  const NeedLogin({this.adminOnly = false});

  /// Validate access from decoded JWT payload.
  bool hasAccess(Map<String, dynamic> payload) {
    if (!adminOnly) return true;
    final userType = payload['userType']?.toString().decryptBasic.userTypeFromString;
    return userType == UserType.ADMIN || userType == UserType.SUPER_ADMIN;
  }
}
