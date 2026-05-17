import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:wakitaki/feature/audio/presentation/widget/audio_visualizer.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/widget/animated_icon_switcher.dart';
import '../manager/recording_cubit.dart';

class RecordingPage extends StatefulWidget {
  static const path = 'recording';
  static const name = 'RecordingPage';
  const RecordingPage._();

  @override
  State<RecordingPage> createState() => _RecordingPageState();

  static Widget buildPage() => MultiBlocProvider(
    providers: [BlocProvider<RecordingCubit>(create: (_) => GetIt.instance<RecordingCubit>())],
    child: RecordingPage._(),
  );
}

class _RecordingPageState extends State<RecordingPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(body: _buildBody());
  }

  Widget _buildBody() => MultiBlocListener(
    listeners: [
      BlocListener<RecordingCubit, RecordingState>(
        listener: (context, state) {
          if (state is RecordingFailureState) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(state.failure.getMessage(context))));
          }
        },
      ),
    ],
    child: Column(
      children: [
        Expanded(child: const SizedBox()),
        Center(child: _buildRecordingButton()),
      ],
    ),
  );

  Widget _buildRecordingButton() => BlocBuilder<RecordingCubit, RecordingState>(
    builder: (context, state) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (state is RecordingStateSuccess)
          SizedBox(width: 100, height: 32, child: AudioVisualizer(audioData: state.data)),
        Container(
          width: 56,
          height: 56,
          margin: EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.primary),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: switch (state) {
              RecordingStateLoading() => null,
              RecordingStateInitial() ||
              RecordingFailureState() => () => context.read<RecordingCubit>().startRecording(),
              RecordingStateSuccess() => () => context.read<RecordingCubit>().stopRecording(),
            },
            child: Center(
              child: AnimatedIconSwitcher(
                showFirst: state is! RecordingStateSuccess,
                firstIcon: Icon(CupertinoIcons.mic_solid, color: Theme.of(context).colorScheme.onPrimary),
                secondIcon: Icon(
                  CupertinoIcons.mic_slash_fill,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
