import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/diagnostics/diagnostic_log.dart';
import '../../../../core/diagnostics/diagnostics_bridge.dart';
import '../../../../core/diagnostics/tark_log_format.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import 'settings_category_card.dart';
import 'settings_row.dart';

/// Settings → Diagnostics: hand the on-device log back to us, or wipe it.
///
/// The reason this is a user-facing button rather than a debug-menu affair is
/// that the bugs it exists for cannot be reproduced anywhere else. A hotspot
/// session that goes one-way after a screen lock depends on two specific
/// phones, one specific OEM's power manager, and the order two OS callbacks
/// happened to fire in. The only honest way to see it is to read what that
/// phone recorded while it was happening.
///
/// Hidden entirely where there is no share sheet to hand a file to (web,
/// desktop) — a row that cannot do its job is worse than no row.
class DiagnosticsCard extends StatefulWidget {
  const DiagnosticsCard({super.key});

  @override
  State<DiagnosticsCard> createState() => _DiagnosticsCardState();
}

class _DiagnosticsCardState extends State<DiagnosticsCard> {
  int _sizeBytes = 0;

  /// Blocks a second tap while an export is being written and packed. On a
  /// long session this is a compress of a few hundred KB — quick, but not
  /// instant, and two of them racing would each prune the other's file.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  Future<void> _refreshSize() async {
    final size = await DiagnosticLog.sizeOnDisk();
    if (!mounted) return;
    setState(() => _sizeBytes = size);
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    final s = context.getString;
    try {
      final path = await DiagnosticLog.export();
      if (!mounted) return;
      if (path == null) {
        _say(s.settings_log_empty);
        return;
      }
      final shared = await DiagnosticsBridge.shareFile(
        path: path,
        // Deliberately not a text type: the container is gzip + keystream (see
        // TarkLogFormat), and letting a mail client treat it as text is how a
        // binary attachment arrives mangled.
        mimeType: 'application/octet-stream',
        subject: 'Tark diagnostic log (.${TarkLogFormat.extension})',
      );
      if (!mounted) return;
      if (!shared) _say(s.settings_log_share_failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final s = context.getString;
    await DiagnosticLog.clear();
    if (!mounted) return;
    _say(s.settings_log_cleared);
    await _refreshSize();
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Rounded to whole units — the exact byte count answers nothing, and this
  /// number's only job is to tell someone whether it's worth sending over a
  /// mobile connection.
  String _humanSize(BuildContext context) {
    if (_sizeBytes <= 0) return context.getString.settings_log_empty;
    if (_sizeBytes < 1024) return '$_sizeBytes B'.localized(context);
    final kb = _sizeBytes / 1024;
    if (kb < 1024) return '${kb.round()} KB'.localized(context);
    return '${(kb / 1024).toStringAsFixed(1)} MB'.localized(context);
  }

  @override
  Widget build(BuildContext context) {
    if (!DiagnosticsBridge.isSupported) return const SizedBox.shrink();
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.bug_report_rounded,
      title: s.settings_section_diagnostics,
      child: Column(
        children: [
          SettingsRow(
            icon: Icons.ios_share_rounded,
            label: s.settings_share_log,
            subtitle: s.settings_share_log_desc(_humanSize(context)),
            trailing: _busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.amber,
                    ),
                  )
                : Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textSecondary,
                  ),
            onTap: () {
              HapticFeedback.selectionClick();
              _share();
            },
          ),
          Divider(color: AppColors.border, height: 1),
          SettingsRow(
            icon: Icons.delete_outline_rounded,
            label: s.settings_clear_log,
            subtitle: s.settings_clear_log_desc,
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
            ),
            onTap: () {
              HapticFeedback.selectionClick();
              _clear();
            },
          ),
        ],
      ),
    );
  }
}
