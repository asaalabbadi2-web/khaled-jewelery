import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme/app_semantic_colors.dart';

class UserAvatarWidget extends StatelessWidget {
  final String displayName;
  final String? photoBase64;
  final double radius;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final bool editable;
  final Future<void> Function(String? base64)? onUpload;

  const UserAvatarWidget({
    super.key,
    required this.displayName,
    this.photoBase64,
    this.radius = 15,
    this.backgroundColor,
    this.foregroundColor,
    this.editable = false,
    this.onUpload,
  });

  @override
  Widget build(BuildContext context) {
    // من الثيم (ثيم-٠): ذهب بنص داكن في الداكن، وسطح بنص ذهبي في الفاتح.
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = backgroundColor ??
        (isDark ? scheme.primary : scheme.surfaceContainerLowest);
    final fgColor = foregroundColor ??
        (isDark ? scheme.onPrimary : AppSemanticColors.of(context).gold.fg);
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';

    ImageProvider? imageProvider;
    if (photoBase64 != null && photoBase64!.isNotEmpty) {
      try {
        final data = photoBase64!.contains(',')
            ? photoBase64!.split(',').last
            : photoBase64!;
        imageProvider = MemoryImage(base64Decode(data));
      } catch (_) {
        imageProvider = null;
      }
    }

    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: bgColor,
      backgroundImage: imageProvider,
      child: imageProvider == null
          ? Text(
              initial,
              style: TextStyle(
                color: fgColor,
                fontWeight: FontWeight.w800,
                fontSize: radius * 0.85,
              ),
            )
          : null,
    );

    if (!editable) return avatar;

    return _EditableAvatar(
      avatar: avatar,
      radius: radius,
      photoBase64: photoBase64,
      onUpload: onUpload,
    );
  }
}

/// widget حالة مستقل يحتفظ بـ GlobalKey لحساب موضع القائمة.
class _EditableAvatar extends StatefulWidget {
  final Widget avatar;
  final double radius;
  final String? photoBase64;
  final Future<void> Function(String? base64)? onUpload;

  const _EditableAvatar({
    required this.avatar,
    required this.radius,
    this.photoBase64,
    this.onUpload,
  });

  @override
  State<_EditableAvatar> createState() => _EditableAvatarState();
}

class _EditableAvatarState extends State<_EditableAvatar> {
  final _key = GlobalKey();

  void _showMenu(BuildContext context) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final offset = box.localToGlobal(Offset.zero);
    final size = box.size;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + size.height + 4,  // أسفل الأفاتار مباشرة
        offset.dx + size.width,
        offset.dy + size.height + 4,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 6,
      items: [
        PopupMenuItem<String>(
          value: 'gallery',
          child: Row(children: const [
            Icon(Icons.photo_library_outlined, size: 20),
            SizedBox(width: 10),
            Text('اختيار من المعرض'),
          ]),
        ),
        // الكاميرا غير مدعومة على الويب
        if (!kIsWeb)
          PopupMenuItem<String>(
            value: 'camera',
            child: Row(children: const [
              Icon(Icons.camera_alt_outlined, size: 20),
              SizedBox(width: 10),
              Text('التقاط صورة'),
            ]),
          ),
        if (widget.photoBase64 != null && widget.photoBase64!.isNotEmpty)
          PopupMenuItem<String>(
            value: 'delete',
            child: Row(children: [
              Icon(Icons.delete_outline, size: 20, color: Theme.of(context).colorScheme.error),
              const SizedBox(width: 10),
              Text('حذف الصورة', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ]),
          ),
      ],
    ).then((action) => _handleAction(context, action));
  }

  Future<void> _handleAction(BuildContext context, String? action) async {
    if (action == null) return;

    if (action == 'delete') {
      try {
        await widget.onUpload?.call(null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم حذف الصورة'), duration: Duration(seconds: 2)),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('فشل حذف الصورة: $e')),
          );
        }
      }
      return;
    }

    final source = action == 'camera' ? ImageSource.camera : ImageSource.gallery;

    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
        requestFullMetadata: false,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              source == ImageSource.camera
                  ? 'تعذّر فتح الكاميرا. تأكد من منح الإذن في الإعدادات.'
                  : 'تعذّر فتح المعرض. تأكد من منح الإذن في الإعدادات.',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    if (picked == null || !mounted) return;

    try {
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) throw Exception('الملف فارغ');

      final ext = picked.name.split('.').last.toLowerCase();
      final mime = (ext == 'png') ? 'image/png' : 'image/jpeg';
      final base64str = 'data:$mime;base64,${base64Encode(bytes)}';

      if (!mounted) return;
      await widget.onUpload?.call(base64str);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تحديث الصورة'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل رفع الصورة: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _key,
      behavior: HitTestBehavior.opaque,
      onTap: () => _showMenu(context),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.avatar,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: widget.radius * 0.9,
              height: widget.radius * 0.9,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  width: 1.5,
                ),
              ),
              child: Icon(
                Icons.camera_alt,
                size: widget.radius * 0.5,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// نسخة مبسّطة لعرض صورة أي موظف (للعرض فقط).
class EmployeeAvatarWidget extends StatelessWidget {
  final String name;
  final String? photoBase64;
  final double radius;

  const EmployeeAvatarWidget({
    super.key,
    required this.name,
    this.photoBase64,
    this.radius = 18,
  });

  @override
  Widget build(BuildContext context) {
    return UserAvatarWidget(
      displayName: name,
      photoBase64: photoBase64,
      radius: radius,
    );
  }
}
