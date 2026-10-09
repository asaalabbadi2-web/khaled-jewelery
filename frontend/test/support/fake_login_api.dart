import 'package:frontend/api_service.dart';
import 'package:http/http.dart' as http;

/// The server's sign-in as the login screen sees it, in memory: the answers it
/// gives in turn (each a refusal, a dead connection or a success), and every
/// request kept to be read back -- how many were sent, and with which code.
class FakeLoginApi extends ApiService {
  FakeLoginApi(this.answers);

  /// Each: a [LoginRefused], an [Exception] (nobody answers), or 'ok'.
  final List<Object> answers;
  final sent = <({String username, String password, String? otp})>[];

  @override
  Future<Map<String, dynamic>> loginWithToken(
    String username,
    String password, {
    String? otp,
  }) async {
    sent.add((username: username, password: password, otp: otp));
    final next = answers[sent.length <= answers.length ? sent.length - 1 : answers.length - 1];
    if (next is LoginRefused) throw next;
    if (next is Exception) throw next;
    return {
      'success': true,
      'token': 't',
      'user': {
        'id': 1,
        'username': username,
        'full_name': 'مستخدم',
        'is_admin': false,
        'role': 'employee',
      },
    };
  }

  static const wrongPassword = LoginRefused(
    status: 401,
    code: 'invalid_credentials',
    message: 'اسم المستخدم أو كلمة المرور غير صحيحة',
  );
  static const tooMany = LoginRefused(
    status: 429,
    code: 'rate_limited',
    message: 'محاولات كثيرة. الرجاء الانتظار دقيقة ثم المحاولة مرة أخرى',
  );
  static const inactive = LoginRefused(
    status: 403,
    code: 'inactive_account',
    message: 'هذا الحساب غير نشط',
  );
  static const otpRequired =
      LoginRefused(status: 401, code: 'otp_required', message: 'رمز التحقق مطلوب');
  static const otpInvalid =
      LoginRefused(status: 401, code: 'otp_invalid', message: 'رمز التحقق غير صحيح');
  static final nobodyAnswers = http.ClientException('Failed to fetch');
}
