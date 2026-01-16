import 'dart:io';

import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:recipe/utils/config.dart';

class MailController {
  MailController._();

  static MailController mail = MailController._();

  Future<void> sendEmail(List<String> toEmail, String subject, String body) async {
    final smtpServer = SmtpServer('smtpout.secureserver.net', port: 587, username: AppConfig.superAdminEmail, password: 'jeTmof-pegcuc-7nejma', ignoreBadCertificate: true);
    final message = Message()
      ..from = Address(AppConfig.superAdminEmail, 'Recipe App')
      ..recipients.addAll(toEmail)
      ..subject = subject
      ..html = body;

    try {
      await send(message, smtpServer);
    } on MailerException catch (e) {
    }
  }

  Future<void> sendUserCreationSuccessfulEmail(List<String> toEmail, String name, String password) async {
    final smtpServer = SmtpServer('smtpout.secureserver.net', port: 587, username: AppConfig.superAdminEmail, password: 'jeTmof-pegcuc-7nejma', ignoreBadCertificate: true);
    String htmlContent = File('assets/templates/account_created.html').readAsStringSync();
    htmlContent = htmlContent.replaceAll("{{user}}", name);
    htmlContent = htmlContent.replaceAll("{{email}}", toEmail.first);
    htmlContent = htmlContent.replaceAll("{{password}}", password);
    htmlContent = htmlContent.replaceAll("cid:logo", "https://rajasthanlimesuppliers.com/uploads/svg_rls_logo.svg");
    final message = Message()
      ..from = Address(AppConfig.superAdminEmail, 'Recipe App')
      ..recipients.addAll(toEmail)
      ..subject = 'Registration Successful'
      ..html = htmlContent;

    try {
      await send(message, smtpServer);
    } on MailerException catch (e) {
    }
  }
}
