import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../manager/consent_cubit.dart';
import '../manager/consent_state.dart';
import '../page/consent_page.dart';

/// Wraps the whole app and stands in front of it when there is a published
/// document nobody on this device has agreed to.
///
/// ## Why this is a wrapper and not a route
///
/// A redirect in the router would be the obvious place, and it is the wrong
/// one. The gate has to hold whatever the app is currently showing —
/// including a deep link, a home-widget launch, or a route restored from a
/// process death — and a redirect only covers navigations that actually go
/// through the router. Wrapping the builder covers every one of them, with no
/// list of entry points to keep up to date.
///
/// It also keeps the app's state alive underneath: nothing is disposed while
/// the gate is up, so accepting returns the reader to exactly where they
/// were rather than to a cold start.
///
/// ## What it does while there is nothing to ask
///
/// Nothing. [ConsentChecking] is two bundled asset reads, so the child is
/// shown as soon as those land — and the background version check runs
/// alongside, never in front of, the app.
class ConsentGate extends StatefulWidget {
  const ConsentGate({required this.child, this.cubit, super.key});

  final Widget child;

  /// Test seam. Left null in the app, where the cubit comes from the DI
  /// graph; supplied by a widget test so the gate can be driven without a
  /// container.
  final ConsentCubit? cubit;

  @override
  State<ConsentGate> createState() => _ConsentGateState();
}

class _ConsentGateState extends State<ConsentGate> {
  late final ConsentCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = widget.cubit ?? GetIt.instance<ConsentCubit>();
    // The local check first, and on its own: it decides whether the app may
    // run, it cannot fail, and nothing about it waits on a network.
    _cubit.check();
    // Then ask whether anything newer exists. Fire-and-forget by design —
    // see ConsentCubit.refreshInBackground.
    _cubit.refreshInBackground();
  }

  @override
  void dispose() {
    // Owned by the DI graph as a singleton, so it outlives this widget and
    // must not be closed here.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ConsentCubit>.value(
      value: _cubit,
      child: BlocBuilder<ConsentCubit, ConsentState>(
        builder: (context, state) {
          final gate = switch (state) {
            ConsentRequired(:final pending) => ConsentPage(
              pending: pending,
              isSaving: false,
              onAccept: _cubit.accept,
            ),
            ConsentSaving(:final pending) => ConsentPage(
              pending: pending,
              isSaving: true,
              onAccept: () {},
            ),
            // Checking reads two bundled assets and resolves in a frame or
            // two. Showing the app under it rather than a spinner means the
            // overwhelmingly common case — nothing to ask — never flashes a
            // loading state on the way to the product.
            ConsentChecking() || ConsentSatisfied() => null,
          };

          if (gate == null) return widget.child;

          // The gate owns its own Navigator so "read the full text" can push
          // a route without escaping the gate or disturbing the app's own
          // navigation state underneath.
          return Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => gate,
            ),
          );
        },
      ),
    );
  }
}
