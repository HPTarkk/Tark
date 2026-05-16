import 'package:bloc/bloc.dart';

mixin SafeEmitMixin<S> on Cubit<S> {
  @override
  void emit(S state) {
    if (isClosed) return;
    super.emit(state);
  }
}
