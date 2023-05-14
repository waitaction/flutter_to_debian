import 'dart:io';

import 'package:mime_type/mime_type.dart';
import 'package:path/path.dart' as path;

import 'vars.dart';

String getBuildBundlePath() {
  final String arch = Vars.debianYaml["flutter_app"]["arch"];

  // build/linux/x64/release/bundle
  return path.join("build/linux/", arch, "release/bundle");
}

Future<String> flutterToDebian(List<String> args) async {
  final Directory tempDir = Directory(
    path.join(
      Directory.systemTemp.path,
      "flutter_debian",
    ),
  );

  if (!(await tempDir.exists())) {
    await tempDir.create(
      recursive: true,
    );
  }

  final String version = Vars.debianYaml["control"]["Version"];
  final String package = Vars.debianYaml["control"]["Package"];
  final String debArch = Vars.debianYaml["control"]["Architecture"];
  final String newPackageName = "${package}_${version}_$debArch";
  final Directory newDebPackageDir = Directory(
    path.join(
      tempDir.path,
      newPackageName,
    ),
  );

  if (await newDebPackageDir.exists()) {
    await newDebPackageDir.delete(
      recursive: true,
    );
  }
  await newDebPackageDir.create(
    recursive: true,
  );

  Vars.newDebPackageDirPath = newDebPackageDir.path;

  // print("new debian package location: ${Vars.newDebPackageDirPath}");

  //Prepare Debian File Structure
  await createFileStructure();

  await addDesktopBuildBundle(
    package,
  );

  await addDesktopDataFiles(
    package,
  );

  await addDesktopDebianControl();
  await addDebianPreInstall();
  await addPackageMaintainerScripts();

  await buildDebianPackage();

  return copyBuildToRootProject(
    tempDir.path,
    newPackageName,
  );
}

Future<String> copyBuildToRootProject(
  String tempDir,
  String newPackageName,
) async {
  Directory finalExecDir = Directory("debian/packages");
  if (!(await finalExecDir.exists())) {
    await finalExecDir.create(
      recursive: true,
    );
  }
  return (await File(path.join(
    tempDir,
    newPackageName + ".deb",
  )).copy(
    path.join(
      finalExecDir.path,
      newPackageName + ".deb",
    ),
  ))
      .path;
}

Future<void> buildDebianPackage() async {
  final ProcessResult result = await Process.run(
    "dpkg-deb",
    [
      "--build",
      Vars.newDebPackageDirPath,
    ],
  );

  if (result.exitCode == 0) {
    return;
  } else {
    throw Exception(result.stderr.toString());
  }
}

Future<void> addPackageMaintainerScripts() async {
  Directory scriptsDir = Directory("debian/scripts");
  if (!await scriptsDir.exists() || await scriptsDir.list().isEmpty) return;

  for (var script in ["preinst", "postinst", "prerm", "postrm"]) {
    final scriptFile = File(path.join("debian/scripts", script));
    if (await scriptFile.exists()) {
      scriptFile.copy(path.join(Vars.pathToDebianControl, script));
    }
  }
}

Future<void> addDebianPreInstall() async {
  final isNonInteractive =
      Vars.debianYaml["flutter_app"]["nonInteractive"] ?? false;
  if (isNonInteractive) {
    // package is intended for automated install, don't add
    // the preinst file asking for confirmation
    return;
  }

  final Map control = Vars.debianYaml["control"];
  final String preInstScript = '''
#!/bin/bash
echo "proceeding..."
''';

  File preinstFile = File(
    path.join(
      Vars.pathToDebianControl,
      "preinst",
    ),
  );

  if (!(await preinstFile.exists())) {
    await preinstFile.create();
  }

  await preinstFile.writeAsString(preInstScript);
  final ProcessResult result = await Process.run(
    "sudo",
    [
      "chmod",
      "755",
      preinstFile.path,
    ],
  );

  if (result.exitCode != 0) {
    throw Exception(result.stderr.toString());
  }
}

Future<void> addDesktopDebianControl() async {
  final Map control = Vars.debianYaml["control"];

  // print("controls from debian.yaml: $control");
  String newControl = "";
  File controlFile = File(
    path.join(
      Vars.pathToDebianControl,
      "control",
    ),
  );

  control.forEach((key, value) {
    newControl += "$key:${value ?? ""}\n";
  });

  await controlFile.writeAsString(newControl);
}

Future<void> addDesktopBuildBundle(String package) async {
  // cp -R <source_folder>/* <destination_folder>

  final ProcessResult result = await Process.run(
    "cp",
    [
      "-R",
      getBuildBundlePath(),
      Vars.pathToFinalAppLocation,
    ],
  );

  if (result.exitCode != 0) {
    throw Exception(result.stderr.toString());
  }

  final ProcessResult result1 = await Process.run(
    "mv",
    [
      path.join(Vars.pathToFinalAppLocation, "bundle"),
      path.join(Vars.pathToFinalAppLocation, package),
    ],
  );

  if (result1.exitCode != 0) {
    throw Exception(result.stderr.toString());
  }

  Directory skeleton = Directory("debian/skeleton");
  if (!await skeleton.exists()) {
    print("No skeleton found");
  } else {
    final ProcessResult result = await Process.run(
      "rsync",
      [
        "-a",
        '${skeleton.absolute.path}/',
        Vars.newDebPackageDirPath,
      ],
    );

    if (result.exitCode != 0) {
      throw Exception(result.stderr.toString());
    }
  }
}

Future<void> addDesktopDataFiles(String package) async {
  Directory gui = Directory("debian/gui/");
  if (!await gui.exists()) await gui.create(recursive: true);
  late String desktopFileName;
  String desktop = "";
  for (var data in gui.listSync()) {
    final String fileName = path.basename(data.path);
    final String mimeType = mime(fileName) ?? path.extension(data.path);
    // print("file : $fileName | mimeType: $mimeType");
    if (mimeType.contains("image")) {
      if (desktop.isNotEmpty) {
        desktop += "\n";
      }
      final String icon = path.join(
        Vars.pathToIcons,
        fileName,
      );
      desktop += "Icon=${icon.replaceFirst(
        Vars.newDebPackageDirPath,
        "",
      )}";

      await File(data.path).copy(icon);
    } else if (mimeType.contains("desktop")) {
      final String appExecutableName =
          Vars.debianYaml["flutter_app"]["command"];

      desktop = await File(data.path).readAsString();
      desktop.trim();
      final String execPath = path.join(
        Vars.pathToFinalAppLocation.replaceFirst(
          Vars.newDebPackageDirPath,
          "",
        ),
        package,
        appExecutableName,
      );
      if (!desktop.endsWith("\n")) {
        desktop += "\n";
      }

      final fieldCodes = formatFieldCodes();
      desktop +=
          fieldCodes == "" ? "Exec=$execPath" : "Exec=$execPath $fieldCodes";
      desktop += "\nTryExec=$execPath";
      desktopFileName = fileName;
    }
  }

  await File(
    path.join(
      Vars.pathToApplications,
      desktopFileName,
    ),
  ).writeAsString(desktop);
}

String formatFieldCodes() {
  final String execFieldCodes =
      Vars.debianYaml["flutter_app"]["execFieldCodes"] ?? "";

  if (execFieldCodes == "") {
    return "";
  }

  var fieldCodes = '';

  final formattedFieldCodes =
      execFieldCodes.trim().replaceAll(' ', '').split(',');

  for (final fieldCode in formattedFieldCodes) {
    if (Vars.allowedExecFieldCodes.contains(fieldCode)) {
      fieldCodes += '%$fieldCode ';
    } else {
      throw Exception("Field code %$fieldCode is not allowed");
    }
  }

  return fieldCodes;
}

Future<void> createFileStructure() async {
  ///Create Path to your app's desktop configs. they will
  ///point to this location /usr/share/ after installation
  final List<String> pathsToShare = ["usr", "share"];
  String sharePath = await createFolders(
    pathsToShare,
    Vars.newDebPackageDirPath,
  );

  ///Create applications and icons Folder
  Vars.pathToApplications = (await createAFolder(
    path.join(
      sharePath,
      "applications",
    ),
  ));
  Vars.pathToIcons = (await createAFolder(
    path.join(
      sharePath,
      "icons",
    ),
  ));

  var base = Vars.debianYaml["flutter_app"].containsKey('parent')
      ? Vars.debianYaml["flutter_app"]["parent"]
      : "opt";
  if (base.startsWith('/')) {
    base = base.substring(1);
  }

  ///Create Path to app biuld bundle for debian. this means your app will be
  ///point to this location /opt/[package] after installation
  final List<String> pathsToApp = [base];

  Vars.pathToFinalAppLocation = await createFolders(
    pathsToApp,
    Vars.newDebPackageDirPath,
  );

  ///Create path to the debian control file
  Vars.pathToDebianControl = (await createAFolder(
    path.join(
      Vars.newDebPackageDirPath,
      "DEBIAN",
    ),
  ));
}

Future<String> createFolders(List<String> paths, String root) async {
  String currentPath = root;

  for (var to in paths) {
    Directory directory = Directory(
      path.join(currentPath, to),
    );
    if (!(await directory.exists())) {
      await directory.create(recursive: true);
    }
    currentPath = directory.path;
  }

  return currentPath;
}

Future<String> createAFolder(String pathTo) async {
  Directory directory = Directory(
    pathTo,
  );
  if (!(await directory.exists())) {
    await directory.create();
  }

  return directory.path;
}
