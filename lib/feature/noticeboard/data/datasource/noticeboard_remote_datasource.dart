import 'package:dio/dio.dart';
import 'package:registro_elettronico/feature/noticeboard/data/model/notice/notice_remote_model.dart';
import 'package:registro_elettronico/feature/noticeboard/domain/model/attachment_domain_model.dart';
import 'package:registro_elettronico/feature/noticeboard/domain/model/notice_domain_model.dart';
import 'package:registro_elettronico/core/data/remote/web/web_spaggiari_client.dart';
import 'package:registro_elettronico/feature/authentication/domain/repository/authentication_repository.dart';

class NoticeboardRemoteDatasource {
  final Dio dio;
  final WebSpaggiariClient webSpaggiariClient;
  final AuthenticationRepository authenticationRepository;
  final Dio _webDio = Dio();
  String? _cookie;
  String? _studentId;
  final Map<int, String> _texts = {};

  NoticeboardRemoteDatasource({
    required this.dio,
    required this.webSpaggiariClient,
    required this.authenticationRepository,
  });

  Future<List<NoticeRemoteModel>> getNoticeboard() async {
    try {
      final response = await dio.get('/students/{studentId}/noticeboard');
      final items = response.data is Map
          ? (response.data['items'] as List? ?? const [])
          : const [];
      if (items.isNotEmpty) {
        return items.whereType<Map>().map((item) {
          return NoticeRemoteModel.fromJson(Map<String, dynamic>.from(item));
        }).toList();
      }
    } catch (_) {
      // Fall through to the authenticated web feed.
    }

    await _ensureWebSession();
    final now = DateTime.now();
    final date = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    final response = await _webDio.get(
      'https://web.spaggiari.eu/rest/w1/noticeboarduser/$_studentId/communications',
      queryParameters: {
        'dfilter': 'communications(pubblicazione<=$date,scadenza>=$date)',
      },
      options: Options(headers: {'Cookie': _cookie}),
    );

    final communications = response.data is Map
        ? (response.data['communications'] as List? ?? const [])
        : const [];
    return communications.whereType<Map>().map((item) {
      final json = Map<String, dynamic>.from(item);
      final id = json['id'];
      if (id is int) _texts[id] = json['testo_link'] ?? json['testo'] ?? '';
      return NoticeRemoteModel.fromWebJson(json);
    }).toList();
  }

  Future<Response> readNotice(String? eventCode, int? pubId) async {
    if (eventCode == null || pubId == null) {
      return Response(
        data: const <String, dynamic>{},
        requestOptions: RequestOptions(path: '/noticeboard/read'),
      );
    }
    if (eventCode.startsWith('WEB:')) {
      await _ensureWebSession();
      return _webDio.post(
        'https://web.spaggiari.eu/rest/w1/noticeboarduser/$_studentId/response/${eventCode.substring(4)}/$pubId',
        options: Options(headers: {'Cookie': _cookie}),
      );
    }
    return dio.post('/students/{studentId}/noticeboard/read/$eventCode/$pubId/101');
  }

  Future<Response> downloadNotice({
    required NoticeDomainModel notice,
    required AttachmentDomainModel attachment,
    required String savePath,
    required void Function(int, int) onProgress,
  }) async {
    if (notice.code?.startsWith('WEB:') == true) {
      await _ensureWebSession();
      return _webDio.download(
        'https://web.spaggiari.eu/rest/w1/noticeboarduser/$_studentId/attachments/${notice.code!.substring(4)}/${notice.id}/${attachment.attachNumber}',
        savePath,
        options: Options(headers: {'Cookie': _cookie}),
        onReceiveProgress: onProgress,
      );
    }
    return dio.download(
      '/students/{studentId}/noticeboard/attach/${notice.code}/${notice.id}/${attachment.attachNumber}',
      savePath,
      onReceiveProgress: onProgress,
    );
  }

  Future<void> _ensureWebSession() async {
    if (_cookie != null) return;
    final credentials = await authenticationRepository.getCredentials();
    final profile = credentials.profile;
    final password = credentials.password;
    if (profile?.ident == null || password == null) {
      throw StateError('Missing ClasseViva credentials');
    }
    _studentId = await authenticationRepository.getCurrentStudentId();
    final username = profile!.ident!;
    final session = await webSpaggiariClient.getPHPToken(
      username: username,
      password: password,
    );
    _cookie =
        '$session; weblogin=$username; LAST_REQUESTED_TARGET=cvv';
  }
}
