import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/avatar_picker_grid.dart';
import '../../../../core/widget/localized_counter.dart';
import '../../../walkie/api/walkie_api.dart';
import '../manager/settings_cubit.dart';
import '../widget/account_section.dart';
import '../widget/settings_category_card.dart';

/// The person's profile: their face and radio name, both editable, with the
/// face shown large at the top the way others will see it, and — on builds
/// with sign-in — the optional account underneath.
///
/// Like Advanced settings, [buildPage] takes the running [WalkieTalkieCubit]
/// (if any) through go_router's `extra`, so a change made mid-channel reaches
/// the people in it at once instead of at the next channel.
class ProfilePage extends StatelessWidget {
  const ProfilePage._();

  static Widget buildPage({Object? liveSession}) => BlocProvider<SettingsCubit>(
    create: (_) => SettingsCubit(
      liveSession: liveSession as WalkieTalkieCubit?,
      repository: GetIt.instance<SettingsRepository>(),
    ),
    child: const ProfilePage._(),
  );

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppColors.systemOverlayStyle,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
          title: Text(
            s.profile_title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: StaggeredEntrance(
              children: [
                const _Hero(),
                SettingsCategoryCard(
                  icon: Icons.badge_rounded,
                  title: s.profile_name_label,
                  child: const _NameField(),
                ),
                SettingsCategoryCard(
                  icon: Icons.face_rounded,
                  title: s.profile_avatar_label,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: BlocBuilder<SettingsCubit, SettingsState>(
                      buildWhen: (p, c) => p.myAvatarId != c.myAvatarId,
                      builder: (context, state) => AvatarPickerGrid(
                        selectedId: state.myAvatarId,
                        accent: AppColors.amber,
                        idleRing: AppColors.border,
                        onSelected: context.read<SettingsCubit>().setMyAvatarId,
                      ),
                    ),
                  ),
                ),
                if (AccountSection.visible) const AccountSection(),
              ],
              builder: (context, cards) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: cards,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The face, large, with the name under it: a preview of how this person
/// appears to everyone else. Swaps with a small pop when the face changes.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return BlocBuilder<SettingsCubit, SettingsState>(
      buildWhen: (p, c) => p.myAvatarId != c.myAvatarId || p.myName != c.myName,
      builder: (context, state) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: [
            AnimatedSwitcher(
              duration: reduced ? Duration.zero : AppMotion.sheet,
              switchInCurve: Curves.easeOutBack,
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: Tween<double>(begin: 0.8, end: 1).animate(animation),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: AppAvatar(
                key: ValueKey(state.myAvatarId),
                name: state.myName,
                avatarId: state.myAvatarId,
                size: 112,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              state.myName.isEmpty ? '…' : state.myName,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The radio name, edited in place. Saved on "done" and when the field loses
/// focus (leaving the page included), and never saved blank.
class _NameField extends StatefulWidget {
  const _NameField();

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final SettingsCubit _cubit = context.read<SettingsCubit>();

  @override
  void initState() {
    super.initState();
    _controller.text = _cubit.state.myName;
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      // Put the saved name back rather than leave a blank field that looks
      // as though it took.
      _controller.text = _cubit.state.myName;
      return;
    }
    if (value != _cubit.state.myName) _cubit.setMyName(value);
  }

  @override
  void dispose() {
    _save();
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocListener<SettingsCubit, SettingsState>(
      // The name arrives asynchronously on first open; fill it in unless the
      // person has already started typing.
      listenWhen: (p, c) => p.myName != c.myName,
      listener: (_, state) {
        if (!_focus.hasFocus) _controller.text = state.myName;
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: TextField(
          key: const ValueKey('profile-name-field'),
          controller: _controller,
          focusNode: _focus,
          maxLength: 20,
          textInputAction: TextInputAction.done,
          buildCounter: localizedCounter(
            style: TextStyle(color: AppColors.textSecondary.withAlpha(120)),
          ),
          style: TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: s.name_hint,
            hintStyle: TextStyle(color: AppColors.textSecondary.withAlpha(160)),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.amber),
            ),
          ),
          onSubmitted: (_) => _focus.unfocus(),
        ),
      ),
    );
  }
}
