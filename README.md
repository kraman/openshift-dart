# Dart cartridge for OpenShift

This repository provides a [Dart](https://www.dartlang.org/) based downloadable cartridge for OpenShift.
This cartridge will work on OpenShift Online, and Origin (CentOS).

## Creating an application with this downloadable cartridge

You can create an application using RHC tools by running:

    rhc app create mydartapp https://raw.github.com/kraman/openshift-dart/master/metadata/manifest.yml
    
## Installing locally on OpenShift Origin

Instead of using this as a downloadable cartridge, you can also install this cartridge on your Origin
installation just like the built-in cartridges.

On each node host:

    #clone the git repository on the node
    > git clone https://github.com/kraman/openshift-dart
    
    #install the cartridge
    > oo-admin-cartridge -a install --mco --source openshift-dart
    > restorecon -rv /var/lib/openshift/.cartridge_repository/kraman-dart

On each broker host:
    
    #clear broker and console cartridge cache
    > oo-admin-broker-cache -c --console

Create a sample application (example execution):

    > rhc app create dart dart --no-dns
    Using kraman-dart-1.1 (DartLang 1.1) for 'dart'

    Application Options
    -------------------
    Domain:     localns
    Cartridges: kraman-dart-1.1
    Gear Size:  default
    Scaling:    no

    Creating application 'dart' ... done


    Your application 'dart' is now available.

      URL:        http://dart-localns.openshift.local/
      SSH to:     52e17d71a1173e8c9b0000ca@dart-localns.openshift.local
      Git remote: ssh://52e17d71a1173e8c9b0000ca@dart-localns.openshift.local/~/git/dart.git/

    Run 'rhc show-app dart' for more details about your app.
    
    
## Writing Dart applications

The cartridge expects a ```server.dart``` in the root of the repository which listens on the IP/port specified
in ```OPENSHIFT_DART_IP``` and ```OPENSHIFT_DART_PORT``` environment variables. A sample ```server.dart``` has
been provided. Log files should be stored in ```OPENSHIFT_DART_LOG_DIR```.

### Dart Application Builds

Upon a git push the cartridge tries to build your application. I will execute the following:

    #download dependencies based on pubspec.yaml
    pub get
    #build dart files
    pub build
    dart build.dart --full

## Dart Binaries

This cartridge includes dart binaries compiled for CentOS/RHEL 6.4. It is built using instructions found on [Issue 15506](https://code.google.com/p/dart/issues/detail?id=15506#c1)

An additional patch is added to enable pub build to use OPENSHIFT_DART_PUB_BUILD_IP environment instead of always binding on 127.0.0.1.

    Index: sdk/lib/_internal/pub/lib/src/command/build.dart
    ===================================================================
    --- sdk/lib/_internal/pub/lib/src/command/build.dart  (revision 31979)
    +++ sdk/lib/_internal/pub/lib/src/command/build.dart  (working copy)
    @@ -5,6 +5,7 @@
     library pub.command.build;
     
     import 'dart:async';
    +import 'dart:io';
     
     import 'package:barback/barback.dart';
     import 'package:path/path.dart' as path;
    @@ -63,7 +64,13 @@
           // user-facing, just use an IPv4 address to avoid a weird bug on the
           // OS X buildbots.
           // TODO(rnystrom): Allow specifying mode.
    -      return barback.createServer("127.0.0.1", 0, graph, mode,
    +      var env = Platform.environment;
    +      String barback_address = "127.0.0.1";
    +      if (env['OPENSHIFT_DART_PUB_BUILD_IP'] != null) {
    +        barback_address = env['OPENSHIFT_DART_PUB_BUILD_IP'];
    +      }
    +
    +      return barback.createServer(barback_address, 0, graph, mode,
               builtInTransformers: builtInTransformers,
               watcher: barback.WatcherType.NONE);
         }).then((server) {

## Version History

* 1.0: Initial release of cartridge.
