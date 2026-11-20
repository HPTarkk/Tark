import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/localized_digits_formatter.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/avatar_picker_grid.dart';
import '../../../../core/widget/localized_counter.dart';
import '../manager/settings_cubit.dart';

Future<void> openProfileEditor(BuildContext context, SettingsCubit settings) {
  final profile = settings.state;
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'ProfileEditorPage'),
      builder: (_) => _ProfileEditorPage(
        name: profile.myName,
        avatarId: profile.myAvatarId,
        settings: settings,
      ),
    ),
  );
}

class _ProfileEditorPage extends StatefulWidget {
  const _ProfileEditorPage({
    required this.name,
    required this.avatarId,
    required this.settings,
  });

  final String name;
  final int? avatarId;
  final SettingsCubit settings;

  @override
  State<_ProfileEditorPage> createState() => _ProfileEditorPageState();
}

class _ProfileEditorPageState extends State<_ProfileEditorPage> {
  late final _name = TextEditingController(text: widget.name);
  late String _savedName = widget.name.trim();
  late int? _avatarId = widget.avatarId;
  bool _saving = false;
  bool _nameRequired = false;
  bool _saveFailed = false;

  String get _draftName => _name.text.trim();
  bool get _nameChanged => _draftName != _savedName;
  bool get _avatarChanged => _avatarId != widget.avatarId;

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameChanged ? _draftName : null;
    final avatarId = _avatarChanged ? _avatarId : null;
    if (name == '') {
      setState(() => _nameRequired = true);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      if (name != null) {
        await widget.settings.setMyName(name);
        _savedName = name;
      }
      if (avatarId != null) await widget.settings.setMyAvatarId(avatarId);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveFailed = true;
        });
      }
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: AppColors.systemOverlayStyle,
    child: PopScope(
      canPop: !_saving,
      child: Scaffold(
        key: const ValueKey('profile-editor'),
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            key: const ValueKey('profile-editor-close'),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          ),
          title: Text(
            context.getString.profile_edit,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      child: StaggeredEntrance(
                        beginOffset: const Offset(0, 0.6),
                        builder: (_, sections) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 14,
                          children: sections,
                        ),
                        children: [
                          _editorCard(_nameAndPreview(context)),
                          _editorCard(_avatarPicker(context)),
                        ],
                      ),
                    ),
                  ),
                  Divider(color: AppColors.border, height: 1),
                  _saveBar(context),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _editorCard(Widget child) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.card,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );

  Widget _nameAndPreview(BuildContext context) {
    final s = context.getString;
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: AppColors.border),
    );
    final counter = localizedCounter(
      style: TextStyle(color: AppColors.textSecondary),
    );
    return Row(
      spacing: 14,
      children: [
        ProfileAvatar(name: _draftName, avatarId: _avatarId, size: 64),
        Expanded(
          child: TextField(
            key: const ValueKey('profile-name-field'),
            controller: _name,
            enabled: !_saving,
            maxLength: 20,
            inputFormatters: [LocaleDigitsFormatter.of(context)],
            textInputAction: TextInputAction.done,
            buildCounter:
                (
                  context, {
                  required currentLength,
                  required maxLength,
                  required isFocused,
                }) => isFocused
                ? counter(
                    context,
                    currentLength: currentLength,
                    maxLength: maxLength,
                    isFocused: isFocused,
                  )
                : null,
            onChanged: (_) => setState(() {
              _nameRequired = false;
              _saveFailed = false;
            }),
            decoration: InputDecoration(
              labelText: s.profile_name_label,
              hintText: s.name_hint,
              errorText: _nameRequired ? s.profile_name_required : null,
              errorMaxLines: 3,
              filled: true,
              fillColor: AppColors.surface,
              border: outline,
              enabledBorder: outline,
              focusedBorder: outline.copyWith(
                borderSide: BorderSide(color: AppColors.amber, width: 1.6),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _avatarPicker(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 10,
    children: [
      Semantics(
        header: true,
        child: Text(
          context.getString.profile_avatar_label,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      IgnorePointer(
        ignoring: _saving,
        child: AvatarPickerGrid(
          selectedId: _avatarId,
          accent: AppColors.amber,
          idleRing: AppColors.border,
          columns: 5,
          spacing: 8,
          onSelected: (id) => setState(() {
            _avatarId = id;
            _saveFailed = false;
          }),
        ),
      ),
    ],
  );

  Widget _saveBar(BuildContext context) {
    final s = context.getString;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          if (_saveFailed)
            Semantics(
              liveRegion: true,
              child: Text(
                s.profile_save_error,
                style: TextStyle(color: AppColors.red),
              ),
            ),
          FilledButton(
            key: const ValueKey('profile-save'),
            onPressed: !_saving && (_nameChanged || _avatarChanged)
                ? _save
                : null,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              minimumSize: const Size(0, 48),
              textStyle: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            child: _saving
                ? SizedBox.square(
                    dimension: 19,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.amber,
                      semanticsLabel: s.profile_save,
                    ),
                  )
                : Text(s.profile_save),
          ),
        ],
      ),
    );
  }
}

/// The same framed avatar on the profile and in its live editor preview.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    required this.name,
    required this.avatarId,
    this.size = 76,
    super.key,
  });

  final String name;
  final int? avatarId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final accent = AppColors.amber;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: accent.withValues(alpha: 0.6), width: 2),
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.22), blurRadius: 20),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (!reduced && avatarId != null)
            Positioned.fill(
              child: TweenAnimationBuilder<double>(
                key: ValueKey(avatarId),
                tween: Tween(begin: 0, end: 1),
                curve: AppMotion.easeOut,
                duration: AppMotion.entrance,
                builder: (_, progress, _) => Transform.scale(
                  scale: 1.05 + progress * 0.38,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: accent.withValues(alpha: 0.65 * (1 - progress)),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          AnimatedSwitcher(
            duration: reduced ? Duration.zero : AppMotion.sheet,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.leaving,
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: Tween<double>(begin: 0.85, end: 1).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: AppAvatar(
              key: ValueKey(avatarId),
              name: name,
              avatarId: avatarId,
              size: size,
            ),
          ),
        ],
      ),
    );
  }
}
