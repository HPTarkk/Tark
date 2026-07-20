import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../manager/wifi_hotspot_cubit.dart';
import 'hotspot_shared_widgets.dart';

/// iOS join side of the hotspot bridge: scan the Android host's Wi-Fi QR and
/// join that network — programmatically when possible, manually otherwise.
class HotspotJoinFlow extends StatefulWidget {
  final VoidCallback onEnterChannel;

  const HotspotJoinFlow({super.key, required this.onEnterChannel});

  @override
  State<HotspotJoinFlow> createState() => _HotspotJoinFlowState();
}

enum _JoinStep { prompt, invalid, joining, joined, manual }

class _HotspotJoinFlowState extends State<HotspotJoinFlow> {
  _JoinStep _step = _JoinStep.prompt;
  HotspotCredentials? _creds;

  Future<void> _scan() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _HostQrScanner()));
    if (raw == null || !mounted) return;
    final creds = HotspotCredentials.fromWifiQr(raw);
    if (creds == null) {
      setState(() => _step = _JoinStep.invalid);
      return;
    }
    setState(() {
      _creds = creds;
      _step = _JoinStep.joining;
    });
    final joined = await context.read<WifiHotspotCubit>().tryJoin(creds);
    if (!mounted) return;
    setState(() => _step = joined ? _JoinStep.joined : _JoinStep.manual);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        HotspotEntrance(
          delayMs: 0,
          child: Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.amber.withAlpha(20),
                border: Border.all(color: AppColors.amber.withAlpha(120)),
              ),
              child: Icon(
                Icons.wifi_find_rounded,
                color: AppColors.amber,
                size: 38,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        HotspotEntrance(
          delayMs: 80,
          child: Text(
            s.hotspot_ios_instructions,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 24),
        if (_step == _JoinStep.invalid)
          HotspotEntrance(
            delayMs: 0,
            child: HotspotInlineNote(
              icon: Icons.error_outline_rounded,
              text: s.hotspot_invalid_qr,
              color: AppColors.red,
            ),
          ),
        if (_step == _JoinStep.joining)
          HotspotPreparing(label: s.hotspot_joining)
        else if (_step == _JoinStep.joined) ...[
          HotspotInlineNote(
            icon: Icons.check_circle_rounded,
            text: s.hotspot_joined,
            color: AppColors.green,
          ),
          const SizedBox(height: 18),
          HotspotPrimaryButton(
            icon: Icons.arrow_forward_rounded,
            label: s.hotspot_enter_channel,
            onTap: widget.onEnterChannel,
          ),
        ] else if (_step == _JoinStep.manual && _creds != null) ...[
          _ManualJoinCard(
            title: s.hotspot_manual_join_title,
            hint: s.hotspot_manual_join_hint,
            network: s.hotspot_network,
            password: s.hotspot_password,
            credentials: _creds!,
            copiedLabel: s.hotspot_copied,
          ),
          const SizedBox(height: 18),
          HotspotPrimaryButton(
            icon: Icons.arrow_forward_rounded,
            label: s.hotspot_enter_channel,
            onTap: widget.onEnterChannel,
          ),
        ] else
          HotspotPrimaryButton(
            icon: Icons.qr_code_scanner_rounded,
            label: s.hotspot_scan_host,
            onTap: _scan,
          ),
      ],
    );
  }
}

class _ManualJoinCard extends StatelessWidget {
  final String title;
  final String hint;
  final String network;
  final String password;
  final HotspotCredentials credentials;
  final String copiedLabel;

  const _ManualJoinCard({
    required this.title,
    required this.hint,
    required this.network,
    required this.password,
    required this.credentials,
    required this.copiedLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          HotspotCredentialRow(
            label: network,
            value: credentials.ssid,
            copiedLabel: copiedLabel,
          ),
          Divider(color: AppColors.border, height: 1),
          HotspotCredentialRow(
            label: password,
            value: credentials.passphrase,
            copiedLabel: copiedLabel,
          ),
        ],
      ),
    );
  }
}

/// Fullscreen viewfinder for the Android host's Wi-Fi QR. Returns the raw
/// scanned string.
class _HostQrScanner extends StatefulWidget {
  const _HostQrScanner();

  @override
  State<_HostQrScanner> createState() => _HostQrScannerState();
}

class _HostQrScannerState extends State<_HostQrScanner> {
  final MobileScannerController _controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    const window = 260.0;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          s.hotspot_scan_host,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final windowRect = Rect.fromCenter(
            center: Offset(
              constraints.maxWidth / 2,
              constraints.maxHeight / 2 - 40,
            ),
            width: window,
            height: window,
          );
          return Stack(
            children: [
              MobileScanner(
                controller: _controller,
                onDetect: (capture) {
                  if (_done) return;
                  for (final barcode in capture.barcodes) {
                    final value = barcode.rawValue;
                    if (value != null && value.isNotEmpty) {
                      _done = true;
                      Navigator.of(context).pop(value);
                      return;
                    }
                  }
                },
              ),
              Positioned.fromRect(
                rect: windowRect.inflate(10),
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: CornerBracketsPainter(
                      color: AppColors.amber,
                      length: 32,
                      stroke: 3.5,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                bottom: 42,
                child: Text(
                  s.hotspot_ios_instructions,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withAlpha(190),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
