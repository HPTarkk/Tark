import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../manager/hotspot_bridge_cubit.dart';

/// The Wi-Fi Hotspot Bridge — the reliable iPhone↔Android path.
///
///  * **Android** (host): creates a local-only Wi-Fi hotspot and shows a Wi-Fi
///    QR + credentials for the iPhone to join. Once a peer is heard over
///    Wi-Fi (or the user taps through), it enters the ordinary Wi-Fi channel.
///  * **iOS** (join): scans the Android host's Wi-Fi QR and joins that network,
///    then enters the channel.
class HotspotBridgePage extends StatefulWidget {
  const HotspotBridgePage._();

  static Widget buildPage() => BlocProvider<HotspotBridgeCubit>(
        create: (_) {
          final cubit = GetIt.instance<HotspotBridgeCubit>();
          if (Platform.isAndroid) cubit.startHost();
          return cubit;
        },
        child: const HotspotBridgePage._(),
      );

  @override
  State<HotspotBridgePage> createState() => _HotspotBridgePageState();
}

class _HotspotBridgePageState extends State<HotspotBridgePage> {
  bool _navigating = false;

  void _enterChannel(BuildContext context) {
    if (_navigating) return;
    setState(() => _navigating = true);
    // Leave the hotspot up — the walkie session runs over it.
    context.goNamed(AppRoutes.walkieName);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () {
            // Backing out without connecting: tear the hotspot down.
            context.read<HotspotBridgeCubit>().stopHost();
            context.pop();
          },
        ),
        title: Text(
          s.hotspot_title,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: BlocConsumer<HotspotBridgeCubit, HotspotBridgeState>(
          listener: (context, state) {
            if (state.peerConnected && !_navigating) _enterChannel(context);
          },
          builder: (context, state) {
            if (!Platform.isAndroid && !Platform.isIOS) {
              return _Message(
                icon: Icons.wifi_tethering_off_rounded,
                text: s.hotspot_not_supported,
              );
            }
            if (_navigating || state.peerConnected) {
              return _ConnectedFlash(label: s.bt_connected);
            }
            if (Platform.isIOS) {
              return _JoinFlow(onEnterChannel: () => _enterChannel(context));
            }
            return _HostFlow(
              state: state,
              onEnterChannel: () => _enterChannel(context),
            );
          },
        ),
      ),
    );
  }
}

// ── Android host ─────────────────────────────────────────────────────────────

class _HostFlow extends StatelessWidget {
  final HotspotBridgeState state;
  final VoidCallback onEnterChannel;

  const _HostFlow({required this.state, required this.onEnterChannel});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    if (state.phase == HotspotPhase.error) {
      return _ErrorCard(
        message: s.hotspot_error,
        onRetry: () => context.read<HotspotBridgeCubit>().startHost(),
      );
    }
    final creds = state.credentials;
    if (state.phase == HotspotPhase.starting || creds == null) {
      return _Preparing(label: s.hotspot_creating);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        _Entrance(delayMs: 0, child: Center(child: _HostBadge(label: s.hotspot_host_badge))),
        const SizedBox(height: 16),
        _Entrance(
          delayMs: 80,
          child: Center(child: GlowingQrCard(data: creds.wifiQrPayload, size: 216)),
        ),
        const SizedBox(height: 18),
        _Entrance(
          delayMs: 140,
          child: _CredentialsCard(
            ssidLabel: s.hotspot_network,
            passwordLabel: s.hotspot_password,
            credentials: creds,
            copiedLabel: s.hotspot_copied,
          ),
        ),
        const SizedBox(height: 18),
        _Entrance(
          delayMs: 200,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                StepRow(index: 1, icon: Icons.photo_camera_rounded, text: s.hotspot_step_scan),
                const SizedBox(height: 12),
                Divider(color: AppColors.border, height: 1),
                const SizedBox(height: 12),
                StepRow(index: 2, icon: Icons.podcasts_rounded, text: s.hotspot_step_join_channel),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        _Entrance(delayMs: 260, child: _WaitingPulse(label: s.hotspot_waiting)),
        const SizedBox(height: 18),
        _Entrance(
          delayMs: 320,
          child: _PrimaryButton(
            icon: Icons.arrow_forward_rounded,
            label: s.hotspot_enter_channel,
            onTap: onEnterChannel,
          ),
        ),
      ],
    );
  }
}

class _HostBadge extends StatelessWidget {
  final String label;

  const _HostBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.green.withAlpha(16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.green.withAlpha(110)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_tethering_rounded, color: AppColors.green, size: 13),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: AppColors.green,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _CredentialsCard extends StatelessWidget {
  final String ssidLabel;
  final String passwordLabel;
  final HotspotCredentials credentials;
  final String copiedLabel;

  const _CredentialsCard({
    required this.ssidLabel,
    required this.passwordLabel,
    required this.credentials,
    required this.copiedLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _CredentialRow(label: ssidLabel, value: credentials.ssid, copiedLabel: copiedLabel),
          Divider(color: AppColors.border, height: 1),
          _CredentialRow(
            label: passwordLabel,
            value: credentials.passphrase,
            copiedLabel: copiedLabel,
          ),
        ],
      ),
    );
  }
}

class _CredentialRow extends StatelessWidget {
  final String label;
  final String value;
  final String copiedLabel;

  const _CredentialRow({required this.label, required this.value, required this.copiedLabel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (value.isNotEmpty)
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('$label $copiedLabel'),
                    duration: const Duration(seconds: 1),
                    backgroundColor: AppColors.card,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.copy_rounded, color: AppColors.amber, size: 18),
              ),
            ),
        ],
      ),
    );
  }
}

class _WaitingPulse extends StatefulWidget {
  final String label;

  const _WaitingPulse({required this.label});

  @override
  State<_WaitingPulse> createState() => _WaitingPulseState();
}

class _WaitingPulseState extends State<_WaitingPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1.0)
          .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(color: AppColors.amber, strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            widget.label,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// ── iOS join ─────────────────────────────────────────────────────────────────

class _JoinFlow extends StatefulWidget {
  final VoidCallback onEnterChannel;

  const _JoinFlow({required this.onEnterChannel});

  @override
  State<_JoinFlow> createState() => _JoinFlowState();
}

enum _JoinStep { prompt, invalid, joining, joined, manual }

class _JoinFlowState extends State<_JoinFlow> {
  _JoinStep _step = _JoinStep.prompt;
  HotspotCredentials? _creds;

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _HostQrScanner()),
    );
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
    final joined = await context.read<HotspotBridgeCubit>().tryJoin(creds);
    if (!mounted) return;
    setState(() => _step = joined ? _JoinStep.joined : _JoinStep.manual);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        _Entrance(
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
              child: Icon(Icons.wifi_find_rounded, color: AppColors.amber, size: 38),
            ),
          ),
        ),
        const SizedBox(height: 20),
        _Entrance(
          delayMs: 80,
          child: Text(
            s.hotspot_ios_instructions,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13.5, height: 1.5),
          ),
        ),
        const SizedBox(height: 24),
        if (_step == _JoinStep.invalid)
          _Entrance(
            delayMs: 0,
            child: _InlineNote(icon: Icons.error_outline_rounded, text: s.hotspot_invalid_qr, color: AppColors.red),
          ),
        if (_step == _JoinStep.joining)
          _Preparing(label: s.hotspot_joining)
        else if (_step == _JoinStep.joined) ...[
          _InlineNote(icon: Icons.check_circle_rounded, text: s.hotspot_joined, color: AppColors.green),
          const SizedBox(height: 18),
          _PrimaryButton(
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
          _PrimaryButton(
            icon: Icons.arrow_forward_rounded,
            label: s.hotspot_enter_channel,
            onTap: widget.onEnterChannel,
          ),
        ] else
          _PrimaryButton(
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
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 6),
          _CredentialRow(label: network, value: credentials.ssid, copiedLabel: copiedLabel),
          Divider(color: AppColors.border, height: 1),
          _CredentialRow(label: password, value: credentials.passphrase, copiedLabel: copiedLabel),
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
        title: Text(s.hotspot_scan_host, style: const TextStyle(color: Colors.white, fontSize: 15)),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final windowRect = Rect.fromCenter(
            center: Offset(constraints.maxWidth / 2, constraints.maxHeight / 2 - 40),
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
                    painter: CornerBracketsPainter(color: AppColors.amber, length: 32, stroke: 3.5),
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
                  style: TextStyle(color: Colors.white.withAlpha(190), fontSize: 13, height: 1.5),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Shared bits ──────────────────────────────────────────────────────────────

class _PrimaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PrimaryButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.amber.withAlpha(25),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.amber.withAlpha(140), width: 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppColors.amber, size: 20),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineNote extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _InlineNote({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withAlpha(16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: AppColors.textPrimary, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _Preparing extends StatelessWidget {
  final String label;

  const _Preparing({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(color: AppColors.amber, strokeWidth: 2.5),
            ),
            const SizedBox(height: 16),
            Text(label, style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _ConnectedFlash extends StatelessWidget {
  final String label;

  const _ConnectedFlash({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.4, end: 1.0),
            duration: const Duration(milliseconds: 450),
            curve: Curves.elasticOut,
            builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.green.withAlpha(26),
                border: Border.all(color: AppColors.green, width: 2),
                boxShadow: [BoxShadow(color: AppColors.green.withAlpha(70), blurRadius: 26)],
              ),
              child: Icon(Icons.check_rounded, color: AppColors.green, size: 42),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            label,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_tethering_off_rounded, color: AppColors.red, size: 40),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 22),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.amber.withAlpha(25),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.amber.withAlpha(120), width: 1.5),
                ),
                child: Text(
                  s.retry,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Message({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.amber, size: 40),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small fade+slide entrance, matching the Bluetooth/Guest journeys.
class _Entrance extends StatefulWidget {
  final Widget child;
  final int delayMs;

  const _Entrance({required this.child, required this.delayMs});

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final CurvedAnimation _anim =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _anim.value,
        child: Transform.translate(offset: Offset(0, 18 * (1 - _anim.value)), child: child),
      ),
    );
  }
}
