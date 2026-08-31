import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/router/routes.dart';
import '../../domain/entity/room_direct_join_bundle.dart';
import '../manager/room_list_cubit.dart';

/// One-scan Room entry. Membership is persisted before transport setup.
class RoomQrJoinPage extends StatefulWidget {
  const RoomQrJoinPage({required this.cubit, super.key});

  static Widget buildPage() => BlocProvider<RoomListCubit>(
    create: (_) => GetIt.instance<RoomListCubit>()..load(),
    child: Builder(
      builder: (context) =>
          RoomQrJoinPage(cubit: context.read<RoomListCubit>()),
    ),
  );

  final RoomListCubit cubit;

  @override
  State<RoomQrJoinPage> createState() => _RoomQrJoinPageState();
}

class _RoomQrJoinPageState extends State<RoomQrJoinPage> {
  bool _busy = false;
  String? _error;

  bool get _fa => Localizations.localeOf(context).languageCode == 'fa';

  Future<void> _onCapture(BarcodeCapture capture) async {
    if (_busy) return;
    String? raw;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        raw = value;
        break;
      }
    }
    if (raw == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final joined = await widget.cubit.joinDirect(
        RoomDirectJoinBundle.decode(raw),
      );
      if (!mounted) return;
      if (joined) {
        context.go(AppRoutes.walkiePath);
      } else {
        setState(() {
          _busy = false;
          _error = _fa
              ? 'پیوستن انجام نشد. دعوت تازه‌ای از میزبان بگیرید.'
              : 'Could not join. Ask the host for a fresh invite.';
        });
      }
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _fa
            ? 'کد دعوت معتبر نیست یا منقضی شده است.'
            : 'The invite is invalid or expired.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final instruction = _fa
        ? 'کد دعوت را اسکن کنید؛ بعد از اسکن مستقیم وارد اتاق می‌شوید.'
        : 'Scan the invite; you will enter the Room directly.';
    return Scaffold(
      appBar: AppBar(title: Text(_fa ? 'پیوستن به اتاق' : 'Join Room')),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              key: const Key('room-join-one-scan'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(instruction, textAlign: TextAlign.center),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text(
                      _error!,
                      key: const Key('room-join-error'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Expanded(
                  child: Semantics(
                    label: instruction,
                    child: MobileScanner(onDetect: _onCapture),
                  ),
                ),
              ],
            ),
            if (_busy)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x99000000),
                  child: Center(
                    child: CircularProgressIndicator(
                      key: Key('room-join-progress'),
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
