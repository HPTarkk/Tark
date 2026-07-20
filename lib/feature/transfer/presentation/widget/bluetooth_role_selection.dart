import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/bluetooth_peer.dart';
import '../manager/bluetooth_connect_cubit.dart';
import 'bluetooth_wifi_bridge_hint.dart';

/// Host / join / reconnect choice — the Bluetooth connect page's first screen.
class BluetoothRoleSelection extends StatelessWidget {
  final Future<bool> Function() onEnsurePermissions;

  const BluetoothRoleSelection({super.key, required this.onEnsurePermissions});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final lastPeer = context.select(
      (BluetoothConnectCubit c) => c.state.lastPeer,
    );
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 12),
        _Entrance(
          delayMs: 0,
          child: _RoleCard(
            icon: Icons.podcasts_rounded,
            title: s.bt_start_session,
            description: s.bt_role_host_desc,
            onTap: () async {
              if (!await onEnsurePermissions()) return;
              if (!context.mounted) return;
              context.read<BluetoothConnectCubit>().startHosting();
            },
          ),
        ),
        const SizedBox(height: 14),
        _Entrance(
          delayMs: 90,
          child: _RoleCard(
            icon: Icons.radar_rounded,
            title: s.bt_find_nearby,
            description: s.bt_role_join_desc,
            onTap: () async {
              if (!await onEnsurePermissions()) return;
              if (!context.mounted) return;
              context.read<BluetoothConnectCubit>().startScanning();
            },
          ),
        ),
        if (lastPeer != null) ...[
          const SizedBox(height: 22),
          _Entrance(
            delayMs: 180,
            child: _ReconnectCard(
              peer: lastPeer,
              onTap: () async {
                if (!await onEnsurePermissions()) return;
                if (!context.mounted) return;
                context.read<BluetoothConnectCubit>().reconnectToLast();
              },
            ),
          ),
        ],
        const SizedBox(height: 26),
        _Entrance(
          delayMs: lastPeer != null ? 270 : 180,
          child: BluetoothWifiBridgeHint(message: s.bt_ios_hint),
        ),
      ],
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border, width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.amber.withAlpha(22),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.amber.withAlpha(110)),
              ),
              child: Icon(icon, color: AppColors.amber, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
              textDirection: Directionality.of(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReconnectCard extends StatelessWidget {
  final BluetoothPeer peer;
  final VoidCallback onTap;

  const _ReconnectCard({required this.peer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.green.withAlpha(12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.green.withAlpha(90), width: 1.5),
        ),
        child: Row(
          children: [
            Icon(Icons.history_rounded, color: AppColors.green, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.bt_last_session,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    peer.name,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.green.withAlpha(26),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppColors.green.withAlpha(140)),
              ),
              child: Text(
                s.bt_reconnect,
                style: TextStyle(
                  color: AppColors.green,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small fade+slide entrance used by the role cards.
class _Entrance extends StatefulWidget {
  final Widget child;
  final int delayMs;

  const _Entrance({required this.child, required this.delayMs});

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final CurvedAnimation _anim = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

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
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - _anim.value)),
          child: child,
        ),
      ),
    );
  }
}
