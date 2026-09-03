import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/widget/qr_scanner_surface.dart';
import '../../domain/entity/room_direct_join_bundle.dart';
import '../manager/room_list_cubit.dart';

/// One-scan Room entry. Membership is persisted before transport setup.
///
/// Wears the same viewfinder as the hotspot scanner and the same amber
/// brackets as the invite QR it is pointed at, so the handoff reads as one
/// instrument rather than three unrelated screens.
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
  String? _error;

  /// Accepts a scanned payload, returning whether this screen is leaving.
  ///
  /// The surface stays locked and green on true and re-arms on false, so a bad
  /// code never strands the user on a dead camera — they simply point it at a
  /// fresh one.
  Future<bool> _onCode(String raw) async {
    final copy = _JoinCopy.of(context);
    try {
      final bundle = RoomDirectJoinBundle.decode(raw);
      // Read before joining so the roster is right the first time it is drawn.
      // A name that appears a beat later reads as the app correcting itself.
      var myName = '';
      try {
        myName = await GetIt.instance<SettingsRepository>().getMyName();
      } catch (_) {
        // Joining offline must not depend on settings storage. Without a name
        // the host's placeholder stands, which is survivable; being unable to
        // join at all is not.
      }
      if (!mounted) return false;
      final joined = await widget.cubit.joinDirect(
        bundle,
        localDisplayName: myName,
      );
      if (!mounted) return false;
      if (joined) {
        context.go(AppRoutes.walkiePath);
        return true;
      }
      setState(() => _error = copy.notJoined);
      return false;
    } on FormatException {
      if (!mounted) return false;
      setState(() => _error = copy.invalid);
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _JoinCopy.of(context);
    return Semantics(
      key: const Key('room-join-one-scan'),
      label: copy.hint,
      child: QrScannerSurface(
        title: copy.title,
        hint: copy.hint,
        searchingLabel: copy.searching,
        lockedLabel: copy.locked,
        busyLabel: copy.joining,
        cameraDeniedLabel: copy.cameraDenied,
        cameraFailedLabel: copy.cameraFailed,
        openSettingsLabel: copy.openSettings,
        errorText: _error,
        onCode: _onCode,
      ),
    );
  }
}

/// Bilingual copy kept local to this page, matching the convention the rest of
/// the Room feature already follows.
final class _JoinCopy {
  const _JoinCopy({required this.fa});

  factory _JoinCopy.of(BuildContext context) => _JoinCopy(
    fa: Localizations.localeOf(context).languageCode.toLowerCase() == 'fa',
  );

  final bool fa;

  String get title => fa ? 'پیوستن به اتاق' : 'JOIN A ROOM';
  String get hint => fa
      ? 'کد دعوت روی گوشی میزبان را بگیر جلوی دوربین. بعد از اسکن مستقیم وارد اتاق می‌شوی.'
      : "Point the camera at the invite on the host's phone. You go straight in.";
  String get searching =>
      fa ? 'دنبال کد دعوت می‌گردم' : 'LOOKING FOR AN INVITE';
  String get locked => fa ? 'کد پیدا شد' : 'INVITE FOUND';
  String get joining => fa ? 'در حال ورود به اتاق' : 'JOINING THE ROOM';
  String get notJoined => fa
      ? 'پیوستن انجام نشد. یک دعوت تازه از میزبان بگیر.'
      : 'Could not join. Ask the host for a fresh invite.';
  String get invalid => fa
      ? 'این کد دعوت معتبر نیست یا منقضی شده.'
      : 'That invite is invalid or expired.';
  String get cameraDenied => fa
      ? '«ترک» برای خواندن کد دعوت دوربین می‌خواهد.'
      : "Tarkk needs the camera to read the host's invite.";
  String get cameraFailed => fa
      ? 'دوربین باز نشد. هر چیز دیگری که از آن استفاده می‌کند را ببند و دوباره امتحان کن.'
      : "The camera wouldn't start. Close whatever else is using it and try again.";
  String get openSettings => fa ? 'باز کردن تنظیمات' : 'OPEN SETTINGS';
}
