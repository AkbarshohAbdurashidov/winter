import 'package:flutter/widgets.dart';

import 'app/diagnostics.dart';
import 'app/winter_app.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(WinterApp(diagnosticsPath: DiagnosticsWriter.pathFromArgs(args)));
}
