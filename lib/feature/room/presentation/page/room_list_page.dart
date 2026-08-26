import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/room.dart';
import '../manager/room_list_cubit.dart';

/// Offline-first manager for durable Rooms.
///
/// This page intentionally does not start Wi-Fi, a hotspot, Bluetooth or a
/// guest link. Selecting a Room changes only durable user intent; transport
/// orchestration begins later from an explicit live-session action.
class RoomListPage extends StatelessWidget {
  const RoomListPage._();

  static Widget buildPage() => BlocProvider<RoomListCubit>(
    create: (_) => GetIt.instance<RoomListCubit>()..load(),
    child: const RoomListPage._(),
  );

  @override
  Widget build(BuildContext context) {
    final copy = _RoomCopy.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        title: Text(copy.title),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('rooms-create'),
        onPressed: () => _createRoom(context),
        backgroundColor: AppColors.amber,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_rounded),
        label: Text(copy.create),
      ),
      body: SafeArea(
        child: BlocBuilder<RoomListCubit, RoomListState>(
          builder: (context, state) {
            if (state.loading && state.rooms.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state.error != null && state.rooms.isEmpty) {
              return _ErrorState(
                copy: copy,
                onRetry: context.read<RoomListCubit>().load,
              );
            }
            if (state.rooms.isEmpty) {
              return _EmptyState(
                copy: copy,
                onCreate: () => _createRoom(context),
              );
            }
            return RefreshIndicator(
              onRefresh: context.read<RoomListCubit>().load,
              child: ListView.separated(
                key: const Key('rooms-list'),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
                itemCount: state.rooms.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final saved = state.rooms[index];
                  return _RoomCard(
                    saved: saved,
                    selected: state.selectedRoomId == saved.room.id,
                    busy: state.loading,
                    copy: copy,
                    onSelect: () =>
                        context.read<RoomListCubit>().select(saved.room.id),
                    onRename: () => _renameRoom(context, saved),
                    onArchive: () => _archiveRoom(context, saved),
                    onLeave: () => _leaveRoom(context, saved),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _createRoom(BuildContext context) async {
    final copy = _RoomCopy.of(context);
    final name = await _nameDialog(
      context,
      title: copy.create,
      action: copy.create,
      hint: copy.roomNameHint,
    );
    if (name == null || !context.mounted) return;

    var localDisplayName = '';
    try {
      localDisplayName = await GetIt.instance<SettingsRepository>().getMyName();
    } catch (_) {
      // Room creation remains available offline even if settings storage is
      // temporarily unavailable. This fallback is local display metadata,
      // never identity or authorization.
    }
    if (!context.mounted) return;
    await context.read<RoomListCubit>().createRoom(
      name: name,
      localDisplayName: localDisplayName.trim().isEmpty
          ? copy.fallbackMemberName
          : localDisplayName.trim(),
    );
  }

  Future<void> _renameRoom(BuildContext context, SavedRoom saved) async {
    final copy = _RoomCopy.of(context);
    final name = await _nameDialog(
      context,
      title: copy.rename,
      action: copy.save,
      hint: copy.roomNameHint,
      initialValue: saved.room.name,
    );
    if (name == null || !context.mounted) return;
    await context.read<RoomListCubit>().rename(saved.room.id, name);
  }

  Future<void> _archiveRoom(BuildContext context, SavedRoom saved) async {
    final copy = _RoomCopy.of(context);
    final confirmed = await _confirm(
      context,
      title: copy.archive,
      body: copy.archiveConfirm(saved.room.name),
      action: copy.archive,
    );
    if (confirmed && context.mounted) {
      await context.read<RoomListCubit>().archive(saved.room.id);
    }
  }

  Future<void> _leaveRoom(BuildContext context, SavedRoom saved) async {
    final copy = _RoomCopy.of(context);
    final confirmed = await _confirm(
      context,
      title: copy.leave,
      body: copy.leaveConfirm(saved.room.name),
      action: copy.leave,
      destructive: true,
    );
    if (confirmed && context.mounted) {
      await context.read<RoomListCubit>().leave(saved.room.id);
    }
  }

  static Future<String?> _nameDialog(
    BuildContext context, {
    required String title,
    required String action,
    required String hint,
    String initialValue = '',
  }) async {
    final copy = _RoomCopy.of(context);
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const Key('room-name-field'),
          controller: controller,
          autofocus: true,
          maxLength: 48,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (value) {
            final trimmed = value.trim();
            if (trimmed.isNotEmpty) Navigator.pop(dialogContext, trimmed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(copy.cancel),
          ),
          FilledButton(
            key: const Key('room-name-submit'),
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isNotEmpty) Navigator.pop(dialogContext, trimmed);
            },
            child: Text(action),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  static Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String action,
    bool destructive = false,
  }) async {
    final copy = _RoomCopy.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(copy.cancel),
              ),
              FilledButton(
                style: destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                      )
                    : null,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.saved,
    required this.selected,
    required this.busy,
    required this.copy,
    required this.onSelect,
    required this.onRename,
    required this.onArchive,
    required this.onLeave,
  });

  final SavedRoom saved;
  final bool selected;
  final bool busy;
  final _RoomCopy copy;
  final VoidCallback onSelect;
  final VoidCallback onRename;
  final VoidCallback onArchive;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final activeMembers = saved.room.members
        .where((member) => member.isActive)
        .length;
    final archived = saved.room.archived;
    return Semantics(
      selected: selected,
      button: !selected && !archived,
      label: copy.roomSemantics(saved.room.name, activeMembers, selected),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppColors.amber : AppColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          key: Key('room-${saved.room.id.value}'),
          borderRadius: BorderRadius.circular(16),
          onTap: busy || selected || archived ? null : onSelect,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        saved.room.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (selected)
                      _StatusChip(
                        label: copy.selected,
                        icon: Icons.check_rounded,
                      )
                    else if (archived)
                      _StatusChip(
                        label: copy.archived,
                        icon: Icons.archive_rounded,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      Icons.group_outlined,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        copy.memberCount(activeMembers),
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    PopupMenuButton<_RoomAction>(
                      key: Key('room-menu-${saved.room.id.value}'),
                      enabled: !busy,
                      tooltip: copy.manage,
                      iconColor: AppColors.textSecondary,
                      onSelected: (action) {
                        switch (action) {
                          case _RoomAction.rename:
                            onRename();
                          case _RoomAction.archive:
                            onArchive();
                          case _RoomAction.leave:
                            onLeave();
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: _RoomAction.rename,
                          child: Text(copy.rename),
                        ),
                        if (!archived)
                          PopupMenuItem(
                            value: _RoomAction.archive,
                            child: Text(copy.archive),
                          ),
                        PopupMenuItem(
                          value: _RoomAction.leave,
                          child: Text(copy.leave),
                        ),
                      ],
                    ),
                  ],
                ),
                if (!selected && !archived) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: busy ? null : onSelect,
                      icon: const Icon(Icons.radio_button_checked_rounded),
                      label: Text(copy.select),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _RoomAction { rename, archive, leave }

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: AppColors.amber.withAlpha(24),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.amber),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: AppColors.amber,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.copy, required this.onCreate});

  final _RoomCopy copy;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_2_outlined, size: 56, color: AppColors.amber),
            const SizedBox(height: 18),
            Text(
              copy.emptyTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              copy.emptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: Text(copy.create),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.copy, required this.onRetry});

  final _RoomCopy copy;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: AppColors.amber),
          const SizedBox(height: 12),
          Text(copy.loadError, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(copy.retry),
          ),
        ],
      ),
    ),
  );
}

/// Small bilingual copy surface kept local to this new page until the next
/// generated-l10n sweep. It provides complete fa/en parity immediately and
/// follows the app's ambient Directionality, including RTL Persian layouts.
final class _RoomCopy {
  const _RoomCopy({required this.fa});

  factory _RoomCopy.of(BuildContext context) => _RoomCopy(
    fa: Localizations.localeOf(context).languageCode.toLowerCase() == 'fa',
  );

  final bool fa;

  String get title => fa ? 'اتاق‌های ذخیره‌شده' : 'Saved rooms';
  String get create => fa ? 'ساخت اتاق' : 'Create room';
  String get rename => fa ? 'تغییر نام' : 'Rename';
  String get save => fa ? 'ذخیره' : 'Save';
  String get archive => fa ? 'بایگانی' : 'Archive';
  String get archived => fa ? 'بایگانی‌شده' : 'Archived';
  String get leave => fa ? 'ترک اتاق' : 'Leave room';
  String get cancel => fa ? 'انصراف' : 'Cancel';
  String get select => fa ? 'انتخاب این اتاق' : 'Select this room';
  String get selected => fa ? 'انتخاب‌شده' : 'Selected';
  String get manage => fa ? 'مدیریت اتاق' : 'Manage room';
  String get retry => fa ? 'تلاش دوباره' : 'Retry';
  String get roomNameHint => fa ? 'نام اتاق' : 'Room name';
  String get fallbackMemberName => fa ? 'راننده' : 'Rider';
  String get emptyTitle => fa ? 'هنوز اتاقی ندارید' : 'No saved rooms yet';
  String get emptyBody => fa
      ? 'اتاق‌ها بدون اینترنت هم روی همین گوشی باقی می‌مانند. ساخت یا انتخاب اتاق به‌تنهایی هات‌اسپات یا میکروفن را روشن نمی‌کند.'
      : 'Rooms stay on this phone offline. Creating or selecting one never starts a hotspot or microphone by itself.';
  String get loadError => fa
      ? 'اتاق‌های ذخیره‌شده خوانده نشدند. چیزی حذف نشده است.'
      : 'Saved rooms could not be loaded. Nothing was deleted.';

  String memberCount(int count) => fa ? '$count عضو' : '$count members';
  String archiveConfirm(String name) => fa
      ? '«$name» بایگانی شود؟ عضویت حذف نمی‌شود.'
      : 'Archive “$name”? Membership is not deleted.';
  String leaveConfirm(String name) => fa
      ? 'عضویت شما در «$name» حذف شود؟ این کار با پایان دادن یک جلسه زنده فرق دارد.'
      : 'Leave “$name”? This removes your membership and is different from ending a live session.';
  String roomSemantics(String name, int count, bool selected) => fa
      ? '$name، $count عضو${selected ? '، انتخاب‌شده' : ''}'
      : '$name, $count members${selected ? ', selected' : ''}';
}
