import "package:stream/stream.dart";
import 'dart:io';

import 'index.rsp.dart';

void main() {
  var env = Platform.environment;
  
  String address = "127.0.0.1";
  if (env['OPENSHIFT_DART_IP'] != null) {
    address = env['OPENSHIFT_DART_IP'];
  }
  
  int port = 8080;
  if (env['OPENSHIFT_DART_PORT'] != null) {
    port = int.parse(env['OPENSHIFT_DART_PORT']); 
  }
  
  var _mapping = {
    "/": index,
  };
  
  StreamServer server = new StreamServer(homeDir: "build", uriMapping: _mapping)
    ..start(address: address, port: port);
}