import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/recovery/recovery_action.dart';
import '../../../../core/recovery/recovery_banner.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../../../../core/recovery/recovery_sheet.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../room/presentation/widget/room_people_sheet.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/walkie_talkie_cubit.dart';

/// Everything the channel screen says about things going wrong.
///
/// The failures worth naming here are the quiet ones. A dropped link already
/// announces itself (see ConnectionHealthBanner); what didn't, until now, was
/// every state where the screen looks perfectly healthy while the user's
/// voice reaches nobody — mic permission refused, a capture device that
/// opened and then delivered nothing, or an IP transport with no local
/// address to send from. All three produce a channel that plays other people
/// flawlessly, which is precisely what makes them so hard to self-diagnose.

// ── Checks ──────────────────────────────────────────────────────────────────

/// Every dependency of a working session, graded, with its fix attached.
///
/// Rendered in full by the troubleshooting sheet — including the healthy
/// rows, which are the point as much as the broken ones: "microphone: working"
/// is what tells someone the problem is at the other end.
List<RecoveryCheck> buildChannelChecks({
  required AppLocalizations s,
  required WalkieTalkieState state,
  required WalkieTalkieCubit cubit,
  required String Function(int) number,
}) {
  return [
    _micCheck(s, state, cubit),
    _networkCheck(s, state, cubit),
    _linkCheck(s, state, cubit),
    _heardCheck(s, state, cubit),
    _peopleCheck(s, state, number),
  ];
}

/// Whether anybody can actually hear this device.
///
/// Every other row here grades something local, and all four of them go green
/// on a phone whose transmissions are going nowhere — which is exactly the
/// report this row exists to answer: "the feedback screen said everything was
/// fine on the phone nobody could hear." The only source for this is the peers
/// themselves (see [PresencePacket.heardIds]), so it stays unknown until one
/// of them has said something either way.
RecoveryCheck _heardCheck(
  AppLocalizations s,
  WalkieTalkieState state,
  WalkieTalkieCubit cubit,
) {
  if (state.unheardByPeers) {
    return RecoveryCheck(
      label: s.check_heard,
      detail: s.check_heard_unheard,
      status: RecoveryStatus.bad,
      actions: [
        RecoveryAction(
          label: s.fix_repair_link,
          isPrimary: true,
          run: () async => cubit.repairSendPath(),
        ),
      ],
    );
  }
  return RecoveryCheck(
    label: s.check_heard,
    detail: s.check_heard_ok,
    // Nobody to be heard by, or nobody who has said yet — neither is a
    // failure, and an unknown is never drawn as one.
    status: state.isReady && state.activeUsers.isNotEmpty
        ? RecoveryStatus.ok
        : RecoveryStatus.unknown,
  );
}

RecoveryCheck _micCheck(
  AppLocalizations s,
  WalkieTalkieState state,
  WalkieTalkieCubit cubit,
) {
  if (!state.hasPermission) {
    return RecoveryCheck(
      label: s.check_mic,
      detail: s.check_mic_denied,
      status: RecoveryStatus.bad,
      actions: [
        RecoveryAction(
          label: s.fix_allow_mic,
          isPrimary: true,
          // Re-asks first: a permission merely denied once is granted from
          // the app's own prompt, which is a far shorter trip than Settings.
          run: cubit.restartMic,
        ),
        RecoveryAction(label: s.open_settings, run: openAppSettings),
      ],
    );
  }
  if (!state.micDelivering) {
    return RecoveryCheck(
      label: s.check_mic,
      detail: s.check_mic_silent,
      status: RecoveryStatus.bad,
      actions: [
        RecoveryAction(
          label: s.fix_restart_mic,
          isPrimary: true,
          run: cubit.restartMic,
        ),
      ],
    );
  }
  return RecoveryCheck(
    label: s.check_mic,
    detail: s.check_mic_ok,
    // Nothing is known about the mic until the session is up — and an
    // unknown is never drawn as a failure.
    status: state.isReady ? RecoveryStatus.ok : RecoveryStatus.unknown,
  );
}

RecoveryCheck _networkCheck(
  AppLocalizations s,
  WalkieTalkieState state,
  WalkieTalkieCubit cubit,
) {
  // Bluetooth and guest links have no IP concept at all — their "network" is
  // the peer connection, which the link row below already grades. Saying
  // anything about Wi-Fi here would just be a red herring.
  if (state.transferMode == TransferMode.bluetooth ||
      state.transferMode == TransferMode.guest) {
    return RecoveryCheck(
      label: s.check_network_bt,
      detail: s.check_network_bt_ok,
      status: state.isReady ? RecoveryStatus.ok : RecoveryStatus.unknown,
    );
  }
  if (state.networkMissing) {
    return RecoveryCheck(
      label: s.check_network,
      detail: s.check_network_none,
      status: RecoveryStatus.bad,
      actions: _networkActions(s, cubit),
    );
  }
  return RecoveryCheck(
    label: s.check_network,
    detail: s.check_network_ok,
    status: state.isReady ? RecoveryStatus.ok : RecoveryStatus.unknown,
  );
}

/// The Wi-Fi panel is Android-only — on iOS no app may raise it, and a chip
/// that does nothing is worse than no chip, so there it's reconnect alone.
List<RecoveryAction> _networkActions(
  AppLocalizations s,
  WalkieTalkieCubit cubit,
) => [
  if (Platform.isAndroid)
    RecoveryAction(
      label: s.fix_wifi_settings,
      isPrimary: true,
      run: cubit.openWifiSettings,
    ),
  RecoveryAction(
    label: s.fix_reconnect,
    isPrimary: !Platform.isAndroid,
    run: () async => cubit.reconnectNow(),
  ),
];

RecoveryCheck _linkCheck(
  AppLocalizations s,
  WalkieTalkieState state,
  WalkieTalkieCubit cubit,
) {
  final retry = RecoveryAction(
    label: s.fix_reconnect,
    isPrimary: true,
    run: () async => cubit.reconnectNow(),
  );
  return switch (state.connectionHealth.status) {
    ConnectionHealthStatus.healthy => RecoveryCheck(
      label: s.check_link,
      detail: s.check_link_ok,
      status: state.isReady ? RecoveryStatus.ok : RecoveryStatus.unknown,
    ),
    // Already retrying on its own, so this is news rather than a job for the
    // user — amber, with the manual shortcut still offered.
    //
    // Degraded is on this branch rather than with healthy. The banner stays
    // silent for it by design, but this sheet is not the banner: the user has
    // opened it to ask what is wrong, and a link that is mid-repair is the
    // honest answer to that question. Reporting it as OK here is how someone
    // ends up staring at four green checks on a phone nobody can hear.
    ConnectionHealthStatus.degraded ||
    ConnectionHealthStatus.reconnecting ||
    ConnectionHealthStatus.renegotiating => RecoveryCheck(
      label: s.check_link,
      detail: s.check_link_retrying,
      status: RecoveryStatus.warn,
      actions: [retry],
    ),
    ConnectionHealthStatus.down => RecoveryCheck(
      label: s.check_link,
      detail: s.check_link_down,
      status: RecoveryStatus.bad,
      actions: [retry],
    ),
  };
}

RecoveryCheck _peopleCheck(
  AppLocalizations s,
  WalkieTalkieState state,
  String Function(int) number,
) {
  final count = state.activeUsers.length;
  if (count > 0) {
    return RecoveryCheck(
      label: s.check_people,
      detail: s.check_people_ok(number(count)),
      status: RecoveryStatus.ok,
    );
  }
  return RecoveryCheck(
    label: s.check_people,
    detail: s.check_people_alone,
    // Amber only once we've waited long enough for it to mean something —
    // before that an empty channel is just a new one.
    status: state.isAlone ? RecoveryStatus.warn : RecoveryStatus.unknown,
  );
}

// ── Banner ──────────────────────────────────────────────────────────────────

/// What the channel screen should be leading with.
enum ChannelIssue {
  /// Nothing to say.
  none,

  /// The channel never opened at all.
  startFailed,

  /// The mic is not permitted.
  micDenied,

  /// No local address, so nothing transmitted can leave the device.
  noNetwork,

  /// The mic is permitted but delivering nothing.
  micSilent,

  /// Transmitting, but the people we can hear report they can't hear us.
  unheard,

  /// Working, but nobody else is here.
  alone,
}

/// Picks the single most important thing currently wrong.
///
/// Deliberately one at a time. Stacking three cards on a screen someone is
/// using at arm's length on a motorbike helps nobody; the sheet is where the
/// full picture lives. Order is by how completely each one stops the user
/// being heard — and a channel that never opened outranks a mic that can't,
/// which outranks having nowhere to send.
///
/// Pure, so the priority order can be pinned down in tests without standing
/// up a cubit and its ten dependencies.
ChannelIssue channelIssueOf(WalkieTalkieState state) {
  if (state.startFailed) return ChannelIssue.startFailed;
  if (!state.hasPermission) return ChannelIssue.micDenied;
  if (state.networkMissing) return ChannelIssue.noNetwork;
  if (!state.micDelivering) return ChannelIssue.micSilent;
  // Below the local failures and above "you're alone": those three are things
  // this phone can see and fix, while this one is a report from the far end —
  // but it still means nothing the user says is arriving, which outranks
  // anything merely quiet.
  if (state.unheardByPeers) return ChannelIssue.unheard;
  // Suppressed while the link is unwell: the health banner is already
  // explaining the silence, and "nobody's here" on top of it would read as a
  // second, separate problem.
  if (state.isAlone && state.connectionHealth.isHealthy) {
    return ChannelIssue.alone;
  }
  return ChannelIssue.none;
}

/// The leading issue as a renderable card, fixes attached — or null when
/// there's nothing to lead with.
RecoveryCheck? primaryChannelIssue({
  required AppLocalizations s,
  required WalkieTalkieState state,
  required WalkieTalkieCubit cubit,
  Future<void> Function()? onInvite,
}) {
  switch (channelIssueOf(state)) {
    case ChannelIssue.none:
      return null;
    case ChannelIssue.startFailed:
      return RecoveryCheck(
        label: s.issue_start_failed_title,
        detail: s.issue_start_failed_body,
        status: RecoveryStatus.bad,
        actions: [
          RecoveryAction(
            label: s.retry,
            isPrimary: true,
            run: cubit.retryStart,
          ),
        ],
      );
    case ChannelIssue.micDenied:
      return RecoveryCheck(
        label: s.issue_mic_denied_title,
        detail: s.issue_mic_denied_body,
        status: RecoveryStatus.bad,
        actions: [
          RecoveryAction(
            label: s.fix_allow_mic,
            isPrimary: true,
            run: cubit.restartMic,
          ),
          RecoveryAction(label: s.open_settings, run: openAppSettings),
        ],
      );
    case ChannelIssue.noNetwork:
      return RecoveryCheck(
        label: s.issue_no_network_title,
        detail: s.issue_no_network_body,
        status: RecoveryStatus.bad,
        actions: _networkActions(s, cubit),
      );
    case ChannelIssue.micSilent:
      return RecoveryCheck(
        label: s.issue_mic_silent_title,
        detail: s.issue_mic_silent_body,
        status: RecoveryStatus.bad,
        actions: [
          RecoveryAction(
            label: s.fix_restart_mic,
            isPrimary: true,
            run: cubit.restartMic,
          ),
        ],
      );
    case ChannelIssue.unheard:
      return RecoveryCheck(
        label: s.issue_unheard_title,
        detail: s.issue_unheard_body,
        status: RecoveryStatus.bad,
        actions: [
          RecoveryAction(
            label: s.fix_repair_link,
            isPrimary: true,
            run: () async => cubit.repairSendPath(),
          ),
        ],
      );
    case ChannelIssue.alone:
      return RecoveryCheck(
        label: s.issue_alone_title,
        detail: s.issue_alone_body,
        status: RecoveryStatus.warn,
        // The only card here whose fix is not a retry: "check the other phone
        // has joined" is advice, and the way to make it true is the invite
        // code. Without this the one screen that says nobody is here was also
        // the one screen with nothing to do about it, and the route back to
        // the code was a pill in the header.
        actions: [
          if (onInvite != null)
            RecoveryAction(
              label: s.fix_invite_someone,
              isPrimary: true,
              run: onInvite,
            ),
        ],
      );
  }
}

/// Drop-in banner for the channel page.
class ChannelIssueBanner extends StatelessWidget {
  const ChannelIssueBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.startFailed != c.startFailed ||
          p.hasPermission != c.hasPermission ||
          p.networkMissing != c.networkMissing ||
          p.micDelivering != c.micDelivering ||
          p.unheardByPeers != c.unheardByPeers ||
          p.isAlone != c.isAlone ||
          p.connectionHealth.isHealthy != c.connectionHealth.isHealthy,
      builder: (context, state) => RecoveryBanner(
        issue: primaryChannelIssue(
          s: context.getString,
          state: state,
          cubit: context.read<WalkieTalkieCubit>(),
          // Straight to the code: the tap on a card that says nobody is here
          // is already the ask, and the roster it would otherwise open holds
          // exactly one row, saying "You".
          onInvite: () => showRoomPeopleSheet(context, autoIssue: true),
        ),
      ),
    );
  }
}

// ── Help entry point ────────────────────────────────────────────────────────

/// The always-there way out.
///
/// Quiet by default — a small text button, not a warning — because most of
/// the time nothing is wrong and the channel screen shouldn't imply
/// otherwise. It turns amber the moment a check goes bad, so when there IS
/// something to find, it draws the eye.
class ChannelHelpButton extends StatelessWidget {
  const ChannelHelpButton({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.isMuteToTheWorld != c.isMuteToTheWorld ||
          p.connectionHealth.isHealthy != c.connectionHealth.isHealthy,
      builder: (context, state) {
        final urgent =
            state.isMuteToTheWorld || !state.connectionHealth.isHealthy;
        final color = urgent ? AppColors.amber : AppColors.textSecondary;
        return TextButton.icon(
          onPressed: () => _open(context),
          style: TextButton.styleFrom(
            foregroundColor: color,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(
            urgent ? Icons.error_outline_rounded : Icons.help_outline_rounded,
            size: 14,
            color: color,
          ),
          label: Text(
            context.getString.help_button,
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        );
      },
    );
  }

  void _open(BuildContext context) {
    final cubit = context.read<WalkieTalkieCubit>();
    final s = context.getString;
    // Resolved once, here, where a BuildContext is unambiguously alive — the
    // stream below outlives this frame and must not reach back into it.
    final isFarsi = Localizations.localeOf(context).languageCode == 'fa';
    String number(int n) => localizeDigits('$n', farsi: isFarsi);

    List<RecoveryCheck> build(WalkieTalkieState state) =>
        buildChannelChecks(s: s, state: state, cubit: cubit, number: number);

    showRecoverySheet(
      context,
      initial: build(cubit.state),
      checks: cubit.stream.map(build),
    );
  }
}
