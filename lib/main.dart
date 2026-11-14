import 'package:flutter/widgets.dart';

import 'app/diagnostics.dart';
import 'app/winter_app.dart';

/// Each display runs its own engine; the native side passes `--screen <n>`
/// (0 = first overlay). Diagnostics of extra screens go to `<path>.screen<n>`.
void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final i = args.indexOf('--screen');
  final screen = (i >= 0 && i + 1 < args.length) ? int.tryParse(args[i + 1]) ?? 0 : 0;
  var diagnostics = DiagnosticsWriter.pathFromArgs(args);
  if (diagnostics != null && screen != 0) diagnostics = '$diagnostics.screen$screen';
  runApp(WinterApp(diagnosticsPath: diagnostics));
}
