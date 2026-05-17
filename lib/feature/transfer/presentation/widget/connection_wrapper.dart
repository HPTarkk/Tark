import 'package:flutter/cupertino.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../manager/connection_cubit.dart';

class ConnectionWrapper extends StatefulWidget {
  final Widget child;
  const ConnectionWrapper._({required this.child});

  static Widget wrapper({required Widget child}) => MultiBlocProvider(
    providers: [BlocProvider(create: (context) => GetIt.instance<ConnectionCubit>())],
    child: ConnectionWrapper._(child: child),
  );

  @override
  State<ConnectionWrapper> createState() => _ConnectionWrapperState();
}

class _ConnectionWrapperState extends State<ConnectionWrapper> {
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
