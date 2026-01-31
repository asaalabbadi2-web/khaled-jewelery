import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../services/backup_encryption_service.dart';
import '../services/google_drive_backup_service.dart';
import '../src/web_file_io_stub.dart'
    if (dart.library.js_interop) '../src/web_file_io_web.dart' as web_io;

class BackupRestoreScreen extends StatefulWidget {
  final bool isArabic;

  const BackupRestoreScreen({super.key, required this.isArabic});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  final ApiService _api = ApiService();
  final GoogleDriveBackupService _drive = GoogleDriveBackupService();
  final BackupEncryptionService _encryption = BackupEncryptionService();

  bool _busy = false;
  bool _driveBusy = false;
  String? _driveStatus;
  int _driveListVersion = 0;

  bool _serverDriveBusy = false;
  String? _serverDriveStatus;
  int _serverDriveListVersion = 0;

  bool _encryptForCloud = true;
  bool _useDeviceKeyForCloud = false;

  bool _encryptForLocal = true;
  bool _useDeviceKeyForLocal = false;

  bool _restoreSafetyLoading = true;
  bool _serverIsProduction = false;
  bool _serverDangerousResetsAllowed = false;
  String? _restoreSafetyError;

  bool get _serverAllowsRestore => !_serverIsProduction || _serverDangerousResetsAllowed;

  bool _canRestore({required bool isSystemAdmin}) => isSystemAdmin && _serverAllowsRestore;

  String _restoreBlockedReason({required bool isSystemAdmin}) {
    if (!isSystemAdmin) {
      return 'الاستعادة متاحة لمسؤول النظام فقط (Admin).';
    }
    if (_serverIsProduction && !_serverDangerousResetsAllowed) {
      return 'الاستعادة مقفلة على نسخة الإنتاج. فعّل ALLOW_DANGEROUS_RESETS=true على السيرفر أثناء نافذة صيانة.';
    }
    if (_restoreSafetyError != null) {
      return 'تعذر التحقق من حالة الأمان من السيرفر: ${_restoreSafetyError!}';
    }
    return 'الاستعادة غير متاحة حالياً.';
  }

  Future<void> _loadRestoreSafety() async {
    if (!mounted) return;
    setState(() {
      _restoreSafetyLoading = true;
      _restoreSafetyError = null;
    });
    try {
      final info = await _api.getSystemResetInfo();
      final data = (info['data'] is Map) ? (info['data'] as Map) : <String, dynamic>{};
      final safety = (data['safety'] is Map) ? (data['safety'] as Map) : <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _serverIsProduction = safety['is_production'] == true;
        _serverDangerousResetsAllowed = safety['dangerous_resets_allowed'] == true;
      });
    } catch (e) {
      setState(() {
        _restoreSafetyError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _restoreSafetyLoading = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // Load restore safety settings asynchronously; errors are caught and displayed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadRestoreSafety();
    });
  }

  Future<_PasswordResult?> _promptBackupPassword({required String title}) async {
    final controller = TextEditingController();
    bool obscure = true;
    bool remember = false;

    final res = await showDialog<_PasswordResult>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('أدخل كلمة مرور النسخ الاحتياطي (لا يمكن استرجاعها إذا نسيتها).'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    obscureText: obscure,
                    decoration: InputDecoration(
                      labelText: 'كلمة المرور',
                      suffixIcon: IconButton(
                        onPressed: () => setLocal(() => obscure = !obscure),
                        icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const SizedBox(height: 4),
                  Text(
                    'يمكنك أيضاً استخدام "مفتاح الجهاز" من الإعدادات بدل كلمة المرور.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: () {
                    final pwd = controller.text.trim();
                    if (pwd.isEmpty) {
                      Navigator.of(ctx).pop(null);
                      return;
                    }
                    Navigator.of(ctx).pop(_PasswordResult(pwd, remember));
                  },
                  child: const Text('متابعة'),
                ),
              ],
            );
          },
        );
      },
    );

    return res;
  }

  Future<void> _downloadBackup() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final zipBytes = Uint8List.fromList(await _api.downloadSystemBackupZip());
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      var filename = 'yasargold-backup-$timestamp.zip';

      Uint8List outBytes = zipBytes;
      if (_encryptForLocal) {
        if (_useDeviceKeyForLocal) {
          outBytes = await _encryption.encrypt(
            plaintext: zipBytes,
            useDeviceKey: true,
          );
        } else {
          final pwd = await _promptBackupPassword(title: 'تشفير النسخة قبل الحفظ');
          if (pwd == null) {
            throw StateError('تم إلغاء العملية');
          }
          outBytes = await _encryption.encrypt(
            plaintext: zipBytes,
            password: pwd.password,
            useDeviceKey: false,
          );
        }
        filename = filename.replaceAll('.zip', '.ygbak');
      }

      if (kIsWeb) {
        web_io.downloadBytes(
          filename,
          outBytes,
          _encryptForLocal ? 'application/octet-stream' : 'application/zip',
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تنزيل النسخة الاحتياطية')),
        );
        return;
      }

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'حفظ النسخة الاحتياطية',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['zip', 'ygbak'],
      );

      if (savePath == null || savePath.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إلغاء الحفظ')),
        );
        return;
      }

      final file = File(savePath);
      await file.writeAsBytes(outBytes, flush: true);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم حفظ النسخة: ${file.path}')),
      );

      // Optional: share to cloud/USB apps.
      final shouldShare = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('مشاركة النسخة؟'),
            content: const Text(
              'يمكنك إرسال النسخة إلى Google Drive/Dropbox أو نسخها لفلاش ميموري عبر مشاركة النظام.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('لا'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('مشاركة'),
              ),
            ],
          );
        },
      );

      if (shouldShare == true) {
        if (_encryptForLocal) {
          // Already saved encrypted as .ygbak.
          await Share.shareXFiles(
            [XFile(file.path)],
            text: 'نسخة احتياطية مشفرة من نظام ياسر جولد',
          );
        } else {
          // Ask if user wants to share as ZIP or as an encrypted .ygbak copy.
          final shareEncrypted = await showDialog<bool>(
            context: context,
            builder: (ctx) {
              return AlertDialog(
                title: const Text('نوع المشاركة'),
                content: const Text(
                  'هل تريد مشاركة الملف كـ ZIP عادي أم كنسخة مشفّرة (.ygbak)؟',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('ZIP عادي'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('مشفّر (.ygbak)'),
                  ),
                ],
              );
            },
          );

          if (shareEncrypted == true) {
            // Create a temporary encrypted file for sharing.
            late final Uint8List encryptedBytes;
            if (_useDeviceKeyForLocal) {
              encryptedBytes = await _encryption.encrypt(
                plaintext: zipBytes,
                useDeviceKey: true,
              );
            } else {
              final pwd = await _promptBackupPassword(
                title: 'كلمة مرور لتشفير المشاركة',
              );
              if (pwd == null) {
                throw StateError('تم إلغاء العملية');
              }
              encryptedBytes = await _encryption.encrypt(
                plaintext: zipBytes,
                password: pwd.password,
                useDeviceKey: false,
              );
            }

            final tmp = File(
              '${Directory.systemTemp.path}/$filename'.replaceAll('.zip', '.ygbak'),
            );
            await tmp.writeAsBytes(encryptedBytes, flush: true);
            try {
              await Share.shareXFiles(
                [XFile(tmp.path)],
                text: 'نسخة احتياطية مشفرة من نظام ياسر جولد',
              );
            } finally {
              // Best-effort cleanup.
              try {
                await tmp.delete();
              } catch (_) {}
            }
          } else {
            await Share.shareXFiles(
              [XFile(file.path)],
              text: 'نسخة احتياطية من نظام ياسر جولد',
            );
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل تنزيل النسخة: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreBackup() async {
    if (_busy) return;

    final auth = context.read<AuthProvider>();
    if (!_canRestore(isSystemAdmin: auth.isSystemAdmin)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_restoreBlockedReason(isSystemAdmin: auth.isSystemAdmin))),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('تحذير: استعادة نسخة احتياطية'),
          content: const Text(
            'سيتم استبدال بيانات النظام ببيانات النسخة الاحتياطية. '
            'تأكد أنك تملك نسخة حديثة قبل المتابعة.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('متابعة'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip', 'ygbak'],
      withData: true,
    );

    if (picked == null || picked.files.isEmpty) return;

    final f = picked.files.first;
    final bytes = f.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر قراءة الملف')),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      Uint8List zip = bytes;
      final isEncrypted = f.name.toLowerCase().endsWith('.ygbak');
      if (isEncrypted) {
        if (_useDeviceKeyForLocal) {
          zip = await _encryption.decrypt(encryptedBlob: bytes);
        } else {
          final pwd = await _promptBackupPassword(title: 'فك تشفير النسخة');
          if (pwd == null) {
            throw StateError('تم إلغاء العملية');
          }
          zip = await _encryption.decrypt(
            encryptedBlob: bytes,
            password: pwd.password,
          );
        }
      }

      final res = await _api.restoreSystemBackupZip(
        zipBytes: zip,
        filename: f.name.replaceAll('.ygbak', '.zip'),
      );

      if (!mounted) return;
      final msg = res['message']?.toString() ?? 'تمت الاستعادة.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل الاستعادة: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _driveSignIn() async {
    if (_driveBusy) return;
    setState(() {
      _driveBusy = true;
      _driveStatus = null;
    });
    try {
      await _drive.signIn();
      if (!mounted) return;
      setState(() {
        _driveStatus = 'تم تسجيل الدخول إلى Google Drive';
        _driveListVersion++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _driveStatus = _formatDriveSignInError(e);
      });
    } finally {
      if (mounted) setState(() => _driveBusy = false);
    }
  }

  String _formatDriveSignInError(Object error) {
    final s = error.toString();

    // Common web setup issues
    if (s.contains('ClientID') && (s.contains('not set') || s.contains('غير مضبوط'))) {
      return 'فشل تسجيل الدخول: Client ID غير مضبوط للويب.\n'
          'تأكد من إعداد OAuth Web Client ID وربطه مع التطبيق.';
    }

    // Google People API disabled (google_sign_in_web fetches basic profile via People API)
    if (s.contains('people.googleapis.com') || s.contains('People API') || s.contains('SERVICE_DISABLED')) {
      return 'فشل تسجيل الدخول: خدمات Google غير مفعّلة في مشروعك.\n'
          'فعّل Google People API (وأيضًا Google Drive API) من Google Cloud Console ثم انتظر دقائق وجرّب مرة أخرى.';
    }

    return 'فشل تسجيل الدخول: $error';
  }

  Future<void> _driveSignOut() async {
    if (_driveBusy) return;
    setState(() {
      _driveBusy = true;
      _driveStatus = null;
    });
    try {
      await _drive.signOut();
      if (!mounted) return;
      setState(() {
        _driveStatus = 'تم تسجيل الخروج';
        _driveListVersion++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _driveStatus = 'فشل تسجيل الخروج: $e';
      });
    } finally {
      if (mounted) setState(() => _driveBusy = false);
    }
  }

  Future<void> _uploadBackupToDrive() async {
    if (_driveBusy || _busy) return;
    setState(() {
      _driveBusy = true;
      _driveStatus = null;
    });

    try {
      final zipBytes = Uint8List.fromList(await _api.downloadSystemBackupZip());
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      String filename = 'yasargold-backup-$timestamp.zip';

      Uint8List uploadBytes = zipBytes;
      if (_encryptForCloud) {
        if (_useDeviceKeyForCloud) {
          uploadBytes = await _encryption.encrypt(
            plaintext: zipBytes,
            useDeviceKey: true,
          );
        } else {
          final pwd = await _promptBackupPassword(title: 'تشفير النسخة قبل الرفع');
          if (pwd == null) {
            throw StateError('تم إلغاء العملية');
          }
          uploadBytes = await _encryption.encrypt(
            plaintext: zipBytes,
            password: pwd.password,
            useDeviceKey: false,
          );
        }
        filename = filename.replaceAll('.zip', '.ygbak');
      }

      await _drive.uploadBackupZip(
        filename: filename,
        bytes: uploadBytes,
        mimeType: _encryptForCloud ? 'application/octet-stream' : 'application/zip',
      );
      if (!mounted) return;
      setState(() {
        _driveStatus = 'تم رفع النسخة إلى Google Drive: $filename';
        _driveListVersion++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _driveStatus = 'فشل الرفع: $e';
      });
    } finally {
      if (mounted) setState(() => _driveBusy = false);
    }
  }

  Future<void> _serverDriveUpload() async {
    if (_serverDriveBusy || _busy) return;
    setState(() {
      _serverDriveBusy = true;
      _serverDriveStatus = null;
    });

    try {
      final res = await _api.uploadSystemBackupToDriveServerSide();
      if (!mounted) return;
      setState(() {
        _serverDriveStatus = res['message']?.toString() ?? 'تم رفع النسخة إلى Drive (على السيرفر).';
        _serverDriveListVersion++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverDriveStatus = 'فشل الرفع (على السيرفر): $e';
      });
    } finally {
      if (mounted) setState(() => _serverDriveBusy = false);
    }
  }

  Future<void> _downloadFromServerDrive(String fileId, String? name) async {
    if (_serverDriveBusy || _busy) return;
    setState(() {
      _serverDriveBusy = true;
      _serverDriveStatus = null;
    });
    try {
      final bytes = await _api.downloadDriveBackupServerSide(fileId);
      final filename = (name == null || name.trim().isEmpty)
          ? 'drive-backup-$fileId.zip'
          : name.trim();

      if (kIsWeb) {
        web_io.downloadBytes(
          filename,
          Uint8List.fromList(bytes),
          'application/octet-stream',
        );
        if (!mounted) return;
        setState(() {
          _serverDriveStatus = 'تم تنزيل الملف من Drive (على السيرفر).';
        });
        return;
      }

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'حفظ الملف من Google Drive',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['zip', 'ygbak'],
      );
      if (savePath == null || savePath.trim().isEmpty) {
        if (!mounted) return;
        setState(() {
          _serverDriveStatus = 'تم إلغاء الحفظ.';
        });
        return;
      }
      final file = File(savePath);
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() {
        _serverDriveStatus = 'تم حفظ الملف: ${file.path}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverDriveStatus = 'فشل تنزيل الملف: $e';
      });
    } finally {
      if (mounted) setState(() => _serverDriveBusy = false);
    }
  }

  Future<void> _restoreFromServerDrive(String fileId, String? name) async {
    if (_serverDriveBusy || _busy) return;

    final auth = context.read<AuthProvider>();
    if (!_canRestore(isSystemAdmin: auth.isSystemAdmin)) {
      if (!mounted) return;
      setState(() {
        _serverDriveStatus = _restoreBlockedReason(isSystemAdmin: auth.isSystemAdmin);
      });
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('استعادة من Google Drive (على السيرفر)'),
          content: Text(
            'سيتم تنزيل النسخة من Drive عبر السيرفر ثم استبدال بيانات النظام.\n\n'
            'الملف: ${name ?? fileId}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('متابعة'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() {
      _serverDriveBusy = true;
      _serverDriveStatus = null;
    });

    try {
      final bytes = await _api.downloadDriveBackupServerSide(fileId);
      final filename = (name ?? 'drive-backup.zip').toString();
      final res = await _api.restoreSystemBackupZip(
        zipBytes: bytes,
        filename: filename,
      );
      if (!mounted) return;
      setState(() {
        _serverDriveStatus = res['message']?.toString() ?? 'تمت الاستعادة.';
        _serverDriveListVersion++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverDriveStatus = 'فشل الاستعادة (من Drive على السيرفر): $e';
      });
    } finally {
      if (mounted) setState(() => _serverDriveBusy = false);
    }
  }

  Future<void> _restoreFromDrive(String fileId, String? name) async {
    if (_driveBusy || _busy) return;

    final auth = context.read<AuthProvider>();
    if (!_canRestore(isSystemAdmin: auth.isSystemAdmin)) {
      if (!mounted) return;
      setState(() {
        _driveStatus = _restoreBlockedReason(isSystemAdmin: auth.isSystemAdmin);
      });
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('استعادة من Google Drive'),
          content: Text(
            'سيتم تنزيل النسخة من Drive ثم استبدال بيانات النظام.\n\n'
            'الملف: ${name ?? fileId}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('متابعة'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    setState(() {
      _driveBusy = true;
      _driveStatus = null;
    });

    try {
      final downloaded = await _drive.downloadFileBytes(fileId);
      Uint8List zip = downloaded;

      final isEncrypted = (name ?? '').toLowerCase().endsWith('.ygbak');
      if (isEncrypted) {
        // First try device key (if available). If not, ask for password.
        try {
          zip = await _encryption.decrypt(encryptedBlob: downloaded);
        } catch (_) {
          final pwd = await _promptBackupPassword(title: 'فك تشفير النسخة');
          if (pwd == null) {
            throw StateError('تم إلغاء العملية');
          }
          zip = await _encryption.decrypt(
            encryptedBlob: downloaded,
            password: pwd.password,
          );
        }
      }
      final res = await _api.restoreSystemBackupZip(
        zipBytes: zip,
        filename: (name ?? 'drive-backup.zip').replaceAll('.ygbak', '.zip'),
      );
      if (!mounted) return;
      setState(() {
        _driveStatus = res['message']?.toString() ?? 'تمت الاستعادة.';
        _driveListVersion++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _driveStatus = 'فشل الاستعادة: $e';
      });
    } finally {
      if (mounted) setState(() => _driveBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Safely access providers with fallback handling.
    SettingsProvider? settings;
    AuthProvider? auth;
    bool canRestore = false;
    
    try {
      settings = context.watch<SettingsProvider>();
      auth = context.watch<AuthProvider>();
      canRestore = !_restoreSafetyLoading && _restoreSafetyError == null && _canRestore(isSystemAdmin: auth.isSystemAdmin);
    } catch (e) {
      // Provider not available; use safe defaults
      debugPrint('Warning: Provider access failed in BackupRestoreScreen: $e');
    }

    // Safe default values for settings when provider is unavailable
    final settingsMap = settings?.settings ?? <String, dynamic>{};

    final enabled = settingsMap['backup_auto_enabled'] == true;
    final mode = (settingsMap['backup_auto_mode']?.toString() ?? 'daily')
        .trim()
        .toLowerCase();
    final time = (settingsMap['backup_auto_time']?.toString() ?? '02:00')
        .trim();
    final interval = (settingsMap['backup_auto_interval_minutes'] is num)
        ? (settingsMap['backup_auto_interval_minutes'] as num).toInt()
        : int.tryParse(
              settingsMap['backup_auto_interval_minutes']?.toString() ??
                  '',
            ) ??
            1440;
    final retention = (settingsMap['backup_retention_count'] is num)
        ? (settingsMap['backup_retention_count'] as num).toInt()
        : int.tryParse(
              settingsMap['backup_retention_count']?.toString() ?? '',
            ) ??
            7;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'النسخ الاحتياطي والاستعادة' : 'Backup'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _CardSection(
            title: 'نسخة احتياطية الآن',
            subtitle:
                'تنزيل ملف ZIP يمكنك حفظه على فلاش/سحابة بدون أوامر يدوية.',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('تشفير قبل الحفظ (AES-256)'),
                subtitle: const Text('يحفظ الملف بصيغة .ygbak بدل .zip'),
                value: _encryptForLocal,
                onChanged: _busy
                    ? null
                    : (v) {
                        setState(() {
                          _encryptForLocal = v;
                        });
                      },
              ),
              if (_encryptForLocal)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('استخدام مفتاح الجهاز (بدون كلمة مرور)'),
                  subtitle: const Text('يحفظ مفتاحاً مشفراً في Keychain/Keystore على هذا الجهاز.'),
                  value: _useDeviceKeyForLocal,
                  onChanged: _busy
                      ? null
                      : (v) {
                          setState(() {
                            _useDeviceKeyForLocal = v;
                          });
                        },
                ),
              FilledButton.icon(
                onPressed: _busy ? null : _downloadBackup,
                icon: const Icon(Icons.download),
                label: Text(_busy ? 'جاري...' : 'تنزيل نسخة احتياطية'),
              ),
              if (_encryptForLocal && _useDeviceKeyForLocal)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            await _encryption.forgetSavedKey();
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('تم حذف مفتاح الجهاز المحفوظ')),
                            );
                          },
                    icon: const Icon(Icons.key_off),
                    label: const Text('حذف مفتاح الجهاز'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _CardSection(
            title: 'استعادة',
            subtitle:
                'اختر ملف النسخة الاحتياطية (ZIP) أو الملف المشفّر (.ygbak) لاستعادة قاعدة البيانات.',
            children: [
              if (_restoreSafetyLoading)
                Text(
                  'جاري التحقق من قيود الاستعادة من السيرفر...',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else if (_restoreSafetyError != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'تعذر التحقق من قيود الاستعادة: $_restoreSafetyError',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _loadRestoreSafety,
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة المحاولة'),
                    ),
                  ],
                )
              else
                Text(
                  (_serverIsProduction && !_serverDangerousResetsAllowed)
                      ? 'قيود السيرفر: Production Lock مفعّل (ALLOW_DANGEROUS_RESETS غير مفعّل).'
                      : 'قيود السيرفر: الاستعادة مسموحة حسب إعدادات البيئة.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (kIsWeb)
                Text(
                  'على الويب: اختر الملف من جهازك ثم سيتم رفعه للسيرفر.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                ),
                onPressed: (_busy || !canRestore) ? null : _restoreBackup,
                icon: const Icon(Icons.restore),
                label: Text(_busy ? 'جاري...' : 'استعادة من ملف'),
              ),
              const SizedBox(height: 8),
              Text(
                'ملاحظة: الاستعادة من داخل الواجهة مدعومة حالياً لقاعدة SQLite.\n'
                'في بيئات الإنتاج يُمكن أن تكون مقفلة ما لم يتم تفعيل ALLOW_DANGEROUS_RESETS=true على السيرفر.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (!canRestore && !_restoreSafetyLoading)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _restoreBlockedReason(isSystemAdmin: auth?.isSystemAdmin ?? false),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _CardSection(
            title: 'نسخ سحابي (Google Drive)',
            subtitle:
                'يدعم رفع النسخة الاحتياطية واستعادتها من داخل التطبيق. (يتطلب إعداد Google Sign-In للمشروع).',
            children: [
              _CardSection(
                title: 'Google Drive (على السيرفر - Service Account)',
                subtitle:
                    'يرفع النسخة من السيرفر مباشرةً إلى Drive بدون تسجيل دخول Google في المتصفح. مناسب للإنتاج على IP محلي.',
                children: [
                  FilledButton.icon(
                    onPressed: (_serverDriveBusy || _busy) ? null : _serverDriveUpload,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: Text(_serverDriveBusy ? 'جاري...' : 'رفع نسخة احتياطية الآن (على السيرفر)'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _serverDriveBusy
                        ? null
                        : () {
                            setState(() {
                              _serverDriveStatus = null;
                              _serverDriveListVersion++;
                            });
                          },
                    icon: const Icon(Icons.refresh),
                    label: const Text('تحديث القائمة/الحالة (على السيرفر)'),
                  ),
                  const SizedBox(height: 8),
                  if (_serverDriveStatus != null)
                    Text(
                      _serverDriveStatus!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    key: ValueKey(_serverDriveListVersion),
                    future: _api.listDriveBackupsServerSide(pageSize: 10),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Text('جاري تحميل قائمة النسخ (على السيرفر)...');
                      }
                      if (snapshot.hasError) {
                        return Text('تعذر تحميل القائمة (على السيرفر): ${snapshot.error}');
                      }
                      final files = snapshot.data ?? const <Map<String, dynamic>>[];
                      if (files.isEmpty) {
                        return const Text('لا توجد نسخ على Drive بعد.');
                      }

                      return Column(
                        children: files
                            .where((f) => (f['id']?.toString() ?? '').isNotEmpty)
                            .map((f) {
                              final id = f['id'].toString();
                              final title = (f['name']?.toString() ?? id).trim();
                              final subtitle = (f['createdTime']?.toString() ?? '').trim();
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.cloud_done_outlined),
                                title: Text(title),
                                subtitle: subtitle.isEmpty ? null : Text(subtitle),
                                trailing: Wrap(
                                  spacing: 8,
                                  children: [
                                    OutlinedButton(
                                      onPressed: (_serverDriveBusy || _busy)
                                          ? null
                                          : () => _downloadFromServerDrive(id, f['name']?.toString()),
                                      child: const Text('تنزيل'),
                                    ),
                                    FilledButton(
                                      onPressed: (_serverDriveBusy || _busy || !canRestore)
                                          ? null
                                          : () => _restoreFromServerDrive(id, f['name']?.toString()),
                                      child: const Text('استعادة'),
                                    ),
                                  ],
                                ),
                              );
                            })
                            .toList(),
                      );
                    },
                  ),
                ],
              ),
              const Divider(height: 24),
              if (kIsWeb)
                Text(
                  'على الويب قد يتطلب إعداد OAuth خاص بالويب (Client ID) وربما قيود إضافية حسب بيئة النشر.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _driveBusy ? null : _driveSignIn,
                    icon: const Icon(Icons.login),
                    label: const Text('تسجيل الدخول'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _driveBusy ? null : _driveSignOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('تسجيل الخروج'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _drive.currentUser == null
                    ? 'غير مسجل دخول'
                    : 'الحساب: ${_drive.currentUser!.email}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('تشفير قبل الرفع (AES-256)'),
                subtitle: const Text('يتم تشفير ملف النسخة داخل التطبيق قبل رفعه إلى Drive.'),
                value: _encryptForCloud,
                onChanged: _driveBusy
                    ? null
                    : (v) {
                        setState(() {
                          _encryptForCloud = v;
                        });
                      },
              ),
              if (_encryptForCloud)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('استخدام مفتاح الجهاز (بدون كلمة مرور)'),
                  subtitle: const Text('يحفظ مفتاحاً مشفراً في Keychain/Keystore على هذا الجهاز.'),
                  value: _useDeviceKeyForCloud,
                  onChanged: _driveBusy
                      ? null
                      : (v) {
                          setState(() {
                            _useDeviceKeyForCloud = v;
                          });
                        },
                ),
              if (_encryptForCloud)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _driveBusy
                        ? null
                        : () async {
                            await _encryption.forgetSavedKey();
                            if (!mounted) return;
                            setState(() {
                              _driveStatus = 'تم حذف المفتاح المحفوظ من الجهاز';
                            });
                          },
                    icon: const Icon(Icons.key_off),
                    label: const Text('حذف المفتاح المحفوظ'),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: (_driveBusy || _busy) ? null : _uploadBackupToDrive,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(_driveBusy ? 'جاري...' : 'رفع نسخة احتياطية الآن إلى Drive'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _driveBusy
                    ? null
                    : () {
                        setState(() {
                          _driveStatus = null;
                          _driveListVersion++;
                        });
                      },
                icon: const Icon(Icons.refresh),
                label: const Text('تحديث القائمة/الحالة'),
              ),
              const SizedBox(height: 8),
              if (_driveStatus != null)
                Text(
                  _driveStatus!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 12),
              if (_drive.currentUser == null)
                Text(
                  'سجّل الدخول أولاً لعرض النسخ الموجودة على Drive.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                FutureBuilder(
                  key: ValueKey(_driveListVersion),
                  future: _drive.listBackupZips(pageSize: 10),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Text('جاري تحميل قائمة النسخ...');
                    }
                    if (snapshot.hasError) {
                      return Text('تعذر تحميل القائمة: ${snapshot.error}');
                    }
                    final files = snapshot.data ?? const [];
                    if (files.isEmpty) {
                      return const Text('لا توجد نسخ على Drive بعد.');
                    }

                    return Column(
                      children: files
                          .where((f) => f.id != null)
                          .map((f) {
                            final title = f.name ?? f.id!;
                            final subtitle = (f.createdTime?.toLocal().toString() ?? '').trim();
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.cloud_done_outlined),
                              title: Text(title),
                              subtitle: subtitle.isEmpty ? null : Text(subtitle),
                              trailing: FilledButton(
                                onPressed: (_driveBusy || _busy || !canRestore)
                                    ? null
                                    : () => _restoreFromDrive(f.id!, f.name),
                                child: const Text('استعادة'),
                              ),
                            );
                          })
                          .toList(),
                    );
                  },
                ),
              const SizedBox(height: 8),
              Text(
                'ملاحظة: "سحابي حقيقي" يعني رفع/تنزيل عبر Drive API داخل التطبيق.\n'
                'لدعم Dropbox/OneDrive سنضيف مزودات إضافية بنفس فكرة الخدمة.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CardSection(
            title: 'النسخ الاحتياطي التلقائي (على السيرفر)',
            subtitle:
                'ينشئ السيرفر نسخاً تلقائية ويحتفظ بعدد محدد منها. هذا مفيد عندما يعمل السيرفر 24/7.',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('تفعيل النسخ التلقائي'),
                value: enabled,
                onChanged: _busy
                    ? null
                    : (val) async {
                        if (settings == null) return;
                        await settings.updateSettings({
                          'backup_auto_enabled': val,
                        });
                      },
              ),
              const Divider(height: 24),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tune),
                title: const Text('النمط'),
                subtitle:
                    Text(mode == 'interval' ? 'كل فترة' : 'يوميًا بوقت محدد'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy
                    ? null
                    : () async {
                        final picked = await showDialog<String>(
                          context: context,
                          builder: (ctx) {
                            return SimpleDialog(
                              title: const Text('اختر نمط النسخ'),
                              children: [
                                SimpleDialogOption(
                                  onPressed: () =>
                                      Navigator.of(ctx).pop('daily'),
                                  child: const Text('يوميًا (وقت محدد)'),
                                ),
                                SimpleDialogOption(
                                  onPressed: () =>
                                      Navigator.of(ctx).pop('interval'),
                                  child: const Text('كل فترة (بالدقائق)'),
                                ),
                              ],
                            );
                          },
                        );
                        if (picked == null) return;
                        if (settings == null) return;
                        await settings.updateSettings({'backup_auto_mode': picked});
                      },
              ),
              if (mode != 'interval')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: const Text('وقت النسخ اليومي'),
                  subtitle: Text(time),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy
                      ? null
                      : () async {
                          final now = TimeOfDay.now();
                          final current = _parseTime(time) ?? now;
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: current,
                          );
                          if (picked == null) return;
                          if (settings == null) return;
                          final formatted =
                              '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
                          await settings.updateSettings({'backup_auto_time': formatted});
                        },
                ),
              if (mode == 'interval')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.timer),
                  title: const Text('الفترة (بالدقائق)'),
                  subtitle: Text('كل $interval دقيقة'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy
                      ? null
                      : () async {
                          final controller = TextEditingController(text: '$interval');
                          final picked = await showDialog<int>(
                            context: context,
                            builder: (ctx) {
                              return AlertDialog(
                                title: const Text('تحديد الفترة'),
                                content: TextField(
                                  controller: controller,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'بالدقائق',
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(ctx).pop(),
                                    child: const Text('إلغاء'),
                                  ),
                                  FilledButton(
                                    onPressed: () {
                                      final v = int.tryParse(controller.text.trim());
                                      Navigator.of(ctx).pop(v);
                                    },
                                    child: const Text('حفظ'),
                                  ),
                                ],
                              );
                            },
                          );
                          if (picked == null) return;
                          if (settings == null) return;
                          await settings.updateSettings({
                            'backup_auto_interval_minutes': picked,
                          });
                        },
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.layers_outlined),
                title: const Text('عدد النسخ المحتفظ بها'),
                subtitle: Text('آخر $retention نسخة'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy
                    ? null
                    : () async {
                        final controller = TextEditingController(text: '$retention');
                        final picked = await showDialog<int>(
                          context: context,
                          builder: (ctx) {
                            return AlertDialog(
                              title: const Text('عدد النسخ'),
                              content: TextField(
                                controller: controller,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'عدد النسخ (1 - 365)',
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: const Text('إلغاء'),
                                ),
                                FilledButton(
                                  onPressed: () {
                                    final v = int.tryParse(controller.text.trim());
                                    Navigator.of(ctx).pop(v);
                                  },
                                  child: const Text('حفظ'),
                                ),
                              ],
                            );
                          },
                        );
                        if (picked == null) return;
                        if (settings == null) return;
                        await settings.updateSettings({'backup_retention_count': picked});
                      },
              ),
              const SizedBox(height: 8),
              Text(
                'مهم: النسخ التلقائي يحفظ الملفات على جهاز السيرفر داخل مجلد backend/backups\n'
                'ويمكن تغييره عبر BACKUP_DIR على السيرفر.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }

  TimeOfDay? _parseTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    if (h < 0 || h > 23) return null;
    if (m < 0 || m > 59) return null;
    return TimeOfDay(hour: h, minute: m);
  }
}

class _CardSection extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<Widget> children;

  const _CardSection({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _PasswordResult {
  final String password;
  final bool rememberKey;

  const _PasswordResult(this.password, this.rememberKey);
}
