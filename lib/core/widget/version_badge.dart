import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wakitaki/core/utils/extensions.dart';

class VersionBadge extends StatelessWidget {
  final Color color;
  const VersionBadge({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (_, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        return Text(
          'v${snap.data!.version}'.localized(context),
          style: TextStyle(
            color: color,
            fontSize: 10,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w500,
          ),
        );
      },
    );
  }
}
