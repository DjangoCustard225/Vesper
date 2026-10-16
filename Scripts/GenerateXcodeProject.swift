import Foundation

struct GoBuildConfiguration: Decodable { let excludedSources: [String] }
let goConfiguration = try JSONDecoder().decode(
    GoBuildConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: "Go/Build.json")))
for name in ["Vesper", "VesperGo"] {
    let isGo = name == "VesperGo"
    let infoPath = isGo ? "Go/Info.plist" : "Vesper/Info.plist"
    let bundleID = isGo ? "app.vesper.go" : "app.vesper"
    let excluded = Set(isGo ? goConfiguration.excludedSources.map { "Vesper/" + $0 } : [])
    let fm = FileManager.default
    let infoData = try Data(contentsOf: URL(fileURLWithPath: infoPath))
    guard
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
        let appVersion = info["CFBundleShortVersionString"] as? String,
        let buildNumber = info["CFBundleVersion"] as? String
    else {
        fatalError("\(infoPath) must declare the app version and build number.")
    }
    let sources = (fm.enumerator(atPath: "Vesper")?.allObjects as? [String] ?? [])
        .filter { $0.hasSuffix(".swift") }.sorted().map { "Vesper/" + $0 }.filter { !excluded.contains($0) }
    func id(_ value: Int) -> String { String(format: "%024X", value) }
    var objects: [String] = []
    var sourceRefs: [String: [String]] = [:]
    var sourceBuilds: [String] = []
    for (index, path) in sources.enumerated() {
        let ref = id(0x100000 + index), build = id(0x200000 + index)
        objects.append(
            "\(ref) = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"\(path)\"; sourceTree = SOURCE_ROOT; };"
        )
        objects.append("\(build) = {isa = PBXBuildFile; fileRef = \(ref); };")
        sourceRefs[(path as NSString).deletingLastPathComponent, default: []].append(ref)
        sourceBuilds.append(build)
    }
    var directories = Set(sourceRefs.keys)
    for directory in sourceRefs.keys {
        var parent = (directory as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            directories.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }
    let groupIDs = Dictionary(
        uniqueKeysWithValues: directories.sorted().enumerated().map { ($0.element, id(0x300000 + $0.offset)) }
    )
    for directory in directories.sorted() {
        let subgroups = directories.filter { ($0 as NSString).deletingLastPathComponent == directory }
            .sorted().compactMap { groupIDs[$0] }
        var children = subgroups + (sourceRefs[directory] ?? [])
        if directory == "Vesper" {
            children += [id(300), id(302), id(304), id(311)] + (isGo ? [] : [id(307), id(309)])
        }
        objects.append(
            "\(groupIDs[directory]!) = {isa = PBXGroup; children = (\(children.joined(separator: ","))); name = \"\((directory as NSString).lastPathComponent)\"; sourceTree = \"<group>\"; };"
        )
    }
    objects += [
        "\(id(300)) = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Vesper/Assets.xcassets; sourceTree = SOURCE_ROOT; };",
        "\(id(301)) = {isa = PBXBuildFile; fileRef = \(id(300)); };",
        "\(id(302)) = {isa = PBXFileReference; lastKnownFileType = text.xml; path = Vesper/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT; };",
        "\(id(303)) = {isa = PBXBuildFile; fileRef = \(id(302)); };",
        "\(id(304)) = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = \(infoPath); sourceTree = SOURCE_ROOT; };",
        "\(id(305)) = {isa = PBXFileReference; explicitFileType = wrapper.application; path = \(name).app; sourceTree = BUILT_PRODUCTS_DIR; };",
        "\(id(306)) = {isa = PBXBuildFile; productRef = \(id(401)); };",
        "\(id(307)) = {isa = PBXFileReference; lastKnownFileType = text; path = Vesper/Resources/MPVKit-LICENSE.txt; sourceTree = SOURCE_ROOT; };",
        "\(id(308)) = {isa = PBXBuildFile; fileRef = \(id(307)); };",
        "\(id(309)) = {isa = PBXFileReference; lastKnownFileType = text; path = Vesper/Resources/AetherEngine-LICENSE.txt; sourceTree = SOURCE_ROOT; };",
        "\(id(310)) = {isa = PBXBuildFile; fileRef = \(id(309)); };",
        "\(id(311)) = {isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = Vesper/VesperIcon.icon; sourceTree = SOURCE_ROOT; };",
        "\(id(312)) = {isa = PBXBuildFile; fileRef = \(id(311)); };",
        "\(id(402)) = {isa = XCLocalSwiftPackageReference; relativePath = Dependencies/MPVKit; };",
        "\(id(403)) = {isa = XCSwiftPackageProductDependency; package = \(id(402)); productName = MPVKit; };",
        "\(id(404)) = {isa = PBXBuildFile; productRef = \(id(403)); };",
        "\(id(405)) = {isa = XCLocalSwiftPackageReference; relativePath = Dependencies/AetherEngine; };",
        "\(id(406)) = {isa = XCSwiftPackageProductDependency; package = \(id(405)); productName = AetherEngine; };",
        "\(id(407)) = {isa = PBXBuildFile; productRef = \(id(406)); };",
        "\(id(400)) = {isa = XCLocalSwiftPackageReference; relativePath = \(isGo ? "Go/Core" : "Core"); };",
        "\(id(401)) = {isa = XCSwiftPackageProductDependency; package = \(id(400)); productName = VesperCore; };",
        "\(id(1)) = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }; buildConfigurationList = \(id(10)); compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = \(id(2)); productRefGroup = \(id(3)); projectDirPath = \"\"; projectRoot = \"\"; packageReferences = (\(isGo ? id(400) : [id(400), id(402), id(405)].joined(separator: ","))); targets = (\(id(4))); };",
        "\(id(2)) = {isa = PBXGroup; children = (\(groupIDs["Vesper"]!), \(id(3))); sourceTree = \"<group>\"; };",
        "\(id(3)) = {isa = PBXGroup; children = (\(id(305))); name = Products; sourceTree = \"<group>\"; };",
        "\(id(4)) = {isa = PBXNativeTarget; buildConfigurationList = \(id(11)); buildPhases = (\(id(5)), \(id(6)), \(id(7))); buildRules = (); dependencies = (); name = \(name); packageProductDependencies = (\(isGo ? id(401) : [id(401), id(403), id(406)].joined(separator: ","))); productName = \(name); productReference = \(id(305)); productType = \"com.apple.product-type.application\"; };",
        "\(id(5)) = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\(sourceBuilds.joined(separator: ","))); runOnlyForDeploymentPostprocessing = 0; };",
        "\(id(6)) = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (\(isGo ? id(306) : [id(306), id(404), id(407)].joined(separator: ","))); runOnlyForDeploymentPostprocessing = 0; };",
        "\(id(7)) = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (\((isGo ? [id(301), id(303), id(312)] : [id(301), id(303), id(308), id(310), id(312)]).joined(separator: ","))); runOnlyForDeploymentPostprocessing = 0; };",
        "\(id(10)) = {isa = XCConfigurationList; buildConfigurations = (\(id(12)), \(id(13))); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };",
        "\(id(11)) = {isa = XCConfigurationList; buildConfigurations = (\(id(14)), \(id(15))); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };",
    ]
    if isGo {
        let unused = [307, 308, 309, 310, 402, 403, 404, 405, 406, 407].map { id($0) + " =" }
        objects.removeAll { object in unused.contains { object.hasPrefix($0) } }
    }
    for (index, configurationName) in ["Debug", "Release"].enumerated() {
        let conditions = (isGo ? ["VESPER_GO"] : []) + (index == 0 ? ["DEBUG"] : [])
        let conditionSetting =
            conditions.isEmpty
            ? "" : "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"\(conditions.joined(separator: " "))\";"
        let projectSettings =
            "CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 27.0; SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_OPTIMIZATION_LEVEL = \"\(index == 0 ? "-Onone" : "-O")\"; DEBUG_INFORMATION_FORMAT = \"\(index == 0 ? "dwarf" : "dwarf-with-dsym")\"; \(conditionSetting)"
        let appSettings =
            "ASSETCATALOG_COMPILER_APPICON_NAME = VesperIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = \(buildNumber); GENERATE_INFOPLIST_FILE = YES; INFOPLIST_FILE = \(infoPath); MARKETING_VERSION = \(appVersion); PRODUCT_BUNDLE_IDENTIFIER = \(bundleID); PRODUCT_NAME = \"$(TARGET_NAME)\"; TARGETED_DEVICE_FAMILY = \"1,2\"; LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/Frameworks\"; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = \"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\"; INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = \"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\";"
        objects.append(
            "\(id(12 + index)) = {isa = XCBuildConfiguration; buildSettings = {\(projectSettings)}; name = \(configurationName); };"
        )
        objects.append(
            "\(id(14 + index)) = {isa = XCBuildConfiguration; buildSettings = {\(appSettings)}; name = \(configurationName); };"
        )
    }
    let project =
        "// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"
        + objects.joined(separator: "\n") + "\n}; rootObject = \(id(1)); }\n"
    let schemeDir = name + ".xcodeproj/xcshareddata/xcschemes"
    let reference =
        "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"\(id(4))\" BuildableName=\"\(name).app\" BlueprintName=\"\(name)\" ReferencedContainer=\"container:\(name).xcodeproj\"/>"
    let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="2700" version="1.3">
        <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">\(reference)</BuildActionEntry></BuildActionEntries></BuildAction>
        <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
        <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(reference)</BuildableProductRunnable></LaunchAction>
        <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">\(reference)</BuildableProductRunnable></ProfileAction>
        <AnalyzeAction buildConfiguration="Debug"/>
        <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
        </Scheme>
        """
    let projectPath = name + ".xcodeproj/project.pbxproj"
    let schemePath = schemeDir + "/" + name + ".xcscheme"
    if CommandLine.arguments.contains("--check") {
        guard (try? String(contentsOfFile: projectPath, encoding: .utf8)) == project,
            (try? String(contentsOfFile: schemePath, encoding: .utf8)) == scheme
        else {
            fputs("\(name).xcodeproj is out of date. Run swift Scripts/GenerateXcodeProject.swift.\n", stderr)
            exit(1)
        }
        print("\(name).xcodeproj matches \(sources.count) Swift files.")
    } else {
        try fm.createDirectory(atPath: schemeDir, withIntermediateDirectories: true)
        if (try? String(contentsOfFile: projectPath, encoding: .utf8)) != project {
            try project.write(toFile: projectPath, atomically: true, encoding: .utf8)
        }
        if (try? String(contentsOfFile: schemePath, encoding: .utf8)) != scheme {
            try scheme.write(toFile: schemePath, atomically: true, encoding: .utf8)
        }
        print("Generated \(name).xcodeproj with \(sources.count) Swift files.")
    }

}
