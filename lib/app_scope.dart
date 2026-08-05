import 'package:flutter/widgets.dart';

import 'data/settings.dart';
import 'data/step_repository.dart';
import 'services/native_bridge.dart';

/// Dependency holder for the widget tree.
///
/// A plain InheritedWidget rather than a state-management package: there are
/// exactly three long-lived objects here, and both of the mutable ones are
/// already Listenables that widgets can watch with ListenableBuilder.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.repository,
    required this.settings,
    required this.bridge,
    required super.child,
  });

  final StepRepository repository;
  final Settings settings;
  final NativeBridge bridge;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope found in the widget tree');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      repository != oldWidget.repository ||
      settings != oldWidget.settings ||
      bridge != oldWidget.bridge;
}
