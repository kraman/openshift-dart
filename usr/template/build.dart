import 'package:polymer/builder.dart';
import 'package:stream/rspc.dart' as Rspc;

main(args) {
  build(entryPoints: [], options: parseOptions(args));
  Rspc.build(args);
}
