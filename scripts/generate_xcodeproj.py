#!/usr/bin/env python3
import hashlib
import os
import subprocess
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_DIR = os.path.join(ROOT, "Cauchy")
TESTS_DIR = os.path.join(ROOT, "CauchyTests")


def gid(s: str) -> str:
    return hashlib.md5(("cauchy2_" + s).encode()).hexdigest()[:24].upper()


# A pbxproj is an old-style property list: a bare word may only contain
# letters, digits, `_`, `.`, `/` and `$`. Anything else — a `+` in a file name,
# most obviously — has to be quoted, or the whole project stops parsing.
_BARE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./$")


def pbx(value: str) -> str:
    if value and all(c in _BARE for c in value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


swift_files = []
for dirpath, _, filenames in os.walk(PROJECT_DIR):
    for f in sorted(filenames):
        if f.endswith(".swift"):
            rel = os.path.relpath(os.path.join(dirpath, f), PROJECT_DIR)
            swift_files.append(rel.replace("\\", "/"))
swift_files.sort()

test_files = []
if os.path.isdir(TESTS_DIR):
    for f in sorted(os.listdir(TESTS_DIR)):
        if f.endswith(".swift"):
            test_files.append(f)

files_by_dir = defaultdict(list)
dirs_by_dir = defaultdict(set)
for sf in swift_files:
    d, f = os.path.split(sf)
    files_by_dir[d].append(f)
    if d:
        parts = d.split("/")
        for i in range(len(parts)):
            parent = "/".join(parts[:i])
            dirs_by_dir[parent].add(parts[i])

IDS = {k: gid(k) for k in [
    "project", "target", "sources", "resources", "frameworks", "product",
    "cl_project", "cl_target", "debug_p", "release_p", "debug_t", "release_t",
    "assets", "assets_build", "entitlements", "root", "cauchy_group", "products",
    "fm_build", "fm_ref", "swiftmath_build", "swiftmath_ref", "swiftmath_pkg",
    "swiftmath_product", "swiftterm_build", "swiftterm_product", "swiftterm_pkg",
    "tests_target", "tests_product", "tests_group", "tests_sources",
    "tests_cl", "tests_debug", "tests_release", "tests_dep", "tests_proxy",
]}

test_ref_ids = {f: gid("testfile_" + f) for f in test_files}
test_build_ids = {f: gid("testbuild_" + f) for f in test_files}

group_ids = {}

def group_id(path: str) -> str:
    key = path or "__root__"
    if key not in group_ids:
        group_ids[key] = gid("group_" + key)
    return group_ids[key]

file_ref_ids = {sf: gid("file_" + sf) for sf in swift_files}
build_file_ids = {sf: gid("build_" + sf) for sf in swift_files}

all_dirs = set()
for sf in swift_files:
    d = os.path.dirname(sf)
    if not d:
        continue
    parts = d.split("/")
    for i in range(1, len(parts) + 1):
        all_dirs.add("/".join(parts[:i]))

lines = []

def emit(s=""):
    lines.append(s)

emit("// !$*UTF8*$!")
emit("{")
emit("\tarchiveVersion = 1;")
emit("\tclasses = {};")
emit("\tobjectVersion = 56;")
emit("\tobjects = {\n")

emit("/* Begin PBXBuildFile section */")
for sf in swift_files:
    bn = os.path.basename(sf)
    emit(f'\t\t{build_file_ids[sf]} /* {bn} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_ids[sf]} /* {bn} */; }};')
emit(f'\t\t{IDS["fm_build"]} /* FoundationModels.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {IDS["fm_ref"]} /* FoundationModels.framework */; }};')
emit(f'\t\t{IDS["swiftmath_build"]} /* SwiftMath in Frameworks */ = {{isa = PBXBuildFile; productRef = {IDS["swiftmath_product"]} /* SwiftMath */; }};')
emit(f'\t\t{IDS["assets_build"]} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {IDS["assets"]} /* Assets.xcassets */; }};')
for tf in test_files:
    emit(f'\t\t{test_build_ids[tf]} /* {tf} in Sources */ = {{isa = PBXBuildFile; fileRef = {test_ref_ids[tf]} /* {tf} */; }};')
emit(f'\t\t{IDS["swiftterm_build"]} /* SwiftTerm in Frameworks */ = {{isa = PBXBuildFile; productRef = {IDS["swiftterm_product"]}; }};')
emit("/* End PBXBuildFile section */\n")

emit("/* Begin PBXFileReference section */")
emit(f'\t\t{IDS["product"]} /* Cauchy.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Cauchy.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
for sf in swift_files:
    bn = os.path.basename(sf)
    emit(f'\t\t{file_ref_ids[sf]} /* {bn} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {pbx(bn)}; sourceTree = "<group>"; }};')
emit(f'\t\t{IDS["assets"]} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
emit(f'\t\t{IDS["entitlements"]} /* Cauchy.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Cauchy.entitlements; sourceTree = "<group>"; }};')
emit(f'\t\t{IDS["fm_ref"]} /* FoundationModels.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = FoundationModels.framework; path = System/Library/Frameworks/FoundationModels.framework; sourceTree = SDKROOT; }};')
emit(f'\t\t{IDS["tests_product"]} /* CauchyTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = CauchyTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')
for tf in test_files:
    emit(f'\t\t{test_ref_ids[tf]} /* {tf} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {pbx(tf)}; sourceTree = "<group>"; }};')
emit("/* End PBXFileReference section */\n")

emit("/* Begin PBXFrameworksBuildPhase section */")
emit(f'\t\t{IDS["frameworks"]} /* Frameworks */ = {{ isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({IDS["fm_build"]} /* FoundationModels.framework in Frameworks */, {IDS["swiftmath_build"]} /* SwiftMath in Frameworks */, {IDS["swiftterm_build"]},); runOnlyForDeploymentPostprocessing = 0; }};')
emit("/* End PBXFrameworksBuildPhase section */\n")

emit("/* Begin PBXGroup section */")
emit(f'\t\t{IDS["products"]} /* Products */ = {{ isa = PBXGroup; children = ({IDS["product"]} /* Cauchy.app */, {IDS["tests_product"]} /* CauchyTests.xctest */,); name = Products; sourceTree = "<group>"; }};')
emit(f'\t\t{IDS["cauchy_group"]} /* Cauchy */ = {{ isa = PBXGroup; children = (')
for sub in sorted(dirs_by_dir[""]):
    emit(f'\t\t\t{group_id(sub)} /* {sub} */,')
emit(f'\t\t\t{IDS["assets"]} /* Assets.xcassets */, {IDS["entitlements"]} /* Cauchy.entitlements */,')
emit('\t\t); path = Cauchy; sourceTree = "<group>"; };')

for d in sorted(all_dirs):
    name = os.path.basename(d)
    emit(f'\t\t{group_id(d)} /* {name} */ = {{ isa = PBXGroup; children = (')
    for sub in sorted(dirs_by_dir.get(d, [])):
        emit(f'\t\t\t{group_id(f"{d}/{sub}")} /* {sub} */,')
    for f in sorted(files_by_dir.get(d, [])):
        sf = f"{d}/{f}" if d else f
        emit(f'\t\t\t{file_ref_ids[sf]} /* {f} */,')
    emit(f'\t\t); path = {pbx(name)}; sourceTree = "<group>"; }};')

emit(f'\t\t{IDS["tests_group"]} /* CauchyTests */ = {{ isa = PBXGroup; children = (')
for tf in test_files:
    emit(f'\t\t\t{test_ref_ids[tf]} /* {tf} */,')
emit('\t\t); path = CauchyTests; sourceTree = "<group>"; };')

emit(f'\t\t{IDS["root"]} = {{ isa = PBXGroup; children = ({IDS["cauchy_group"]} /* Cauchy */, {IDS["tests_group"]} /* CauchyTests */, {IDS["products"]} /* Products */,); sourceTree = "<group>"; }};')
emit("/* End PBXGroup section */\n")

emit("/* Begin PBXNativeTarget section */")
emit(f'\t\t{IDS["target"]} /* Cauchy */ = {{ isa = PBXNativeTarget; buildConfigurationList = {IDS["cl_target"]}; buildPhases = ({IDS["sources"]}, {IDS["frameworks"]}, {IDS["resources"]},); buildRules = (); dependencies = (); name = Cauchy; packageProductDependencies = ({IDS["swiftmath_product"]} /* SwiftMath */, {IDS["swiftterm_product"]},); productName = Cauchy; productReference = {IDS["product"]}; productType = "com.apple.product-type.application"; }};')
emit(f'\t\t{IDS["tests_target"]} /* CauchyTests */ = {{ isa = PBXNativeTarget; buildConfigurationList = {IDS["tests_cl"]}; buildPhases = ({IDS["tests_sources"]},); buildRules = (); dependencies = ({IDS["tests_dep"]},); name = CauchyTests; productName = CauchyTests; productReference = {IDS["tests_product"]}; productType = "com.apple.product-type.bundle.unit-test"; }};')
emit("/* End PBXNativeTarget section */\n")

emit("/* Begin PBXContainerItemProxy section */")
emit(f'\t\t{IDS["tests_proxy"]} = {{ isa = PBXContainerItemProxy; containerPortal = {IDS["project"]} /* Project object */; proxyType = 1; remoteGlobalIDString = {IDS["target"]}; remoteInfo = Cauchy; }};')
emit("/* End PBXContainerItemProxy section */\n")

emit("/* Begin PBXTargetDependency section */")
emit(f'\t\t{IDS["tests_dep"]} /* PBXTargetDependency */ = {{ isa = PBXTargetDependency; target = {IDS["target"]} /* Cauchy */; targetProxy = {IDS["tests_proxy"]}; }};')
emit("/* End PBXTargetDependency section */\n")

emit("/* Begin PBXProject section */")
emit(f'\t\t{IDS["project"]} /* Project object */ = {{ isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2600; LastUpgradeCheck = 2600; }}; buildConfigurationList = {IDS["cl_project"]}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {IDS["root"]}; packageReferences = ({IDS["swiftmath_pkg"]} /* XCLocalSwiftPackageReference "SwiftMath" */, {IDS["swiftterm_pkg"]},); productRefGroup = {IDS["products"]}; projectDirPath = ""; projectRoot = ""; targets = ({IDS["target"]}, {IDS["tests_target"]},); }};')
emit("/* End PBXProject section */\n")

emit("/* Begin PBXResourcesBuildPhase section */")
emit(f'\t\t{IDS["resources"]} /* Resources */ = {{ isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({IDS["assets_build"]},); runOnlyForDeploymentPostprocessing = 0; }};')
emit("/* End PBXResourcesBuildPhase section */\n")

emit("/* Begin PBXSourcesBuildPhase section */")
emit(f'\t\t{IDS["sources"]} /* Sources */ = {{ isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (')
for sf in swift_files:
    emit(f'\t\t\t{build_file_ids[sf]},')
emit('\t\t); runOnlyForDeploymentPostprocessing = 0; };')
emit(f'\t\t{IDS["tests_sources"]} /* Sources */ = {{ isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (')
for tf in test_files:
    emit(f'\t\t\t{test_build_ids[tf]},')
emit('\t\t); runOnlyForDeploymentPostprocessing = 0; };')
emit("/* End PBXSourcesBuildPhase section */\n")

def target_settings(cid, name):
    emit(f'\t\t{cid} /* {name} */ = {{ isa = XCBuildConfiguration; buildSettings = {{')
    emit('\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
    emit('\t\t\tCODE_SIGN_ENTITLEMENTS = Cauchy/Cauchy.entitlements;')
    emit('\t\t\tCODE_SIGN_STYLE = Automatic;')
    emit('\t\t\tCOMBINE_HIDPI_IMAGES = YES;')
    emit('\t\t\tCURRENT_PROJECT_VERSION = 1;')
    # No App Sandbox: the app spawns the user's locally installed claude/codex
    # CLIs, which need their own config, keychain access, and network.
    emit('\t\t\tENABLE_APP_SANDBOX = NO;')
    emit('\t\t\tENABLE_HARDENED_RUNTIME = YES;')
    emit('\t\t\tGENERATE_INFOPLIST_FILE = YES;')
    # Merged into the generated Info.plist; declares the PDF document type so
    # Finder "Open With" / double-click routes PDFs to Cauchy.
    emit('\t\t\tINFOPLIST_FILE = Cauchy/Info.plist;')
    emit('\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "cauchy";')
    emit('\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity";')
    emit('\t\t\tLD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/../Frameworks");')
    emit('\t\t\tMACOSX_DEPLOYMENT_TARGET = 26.0;')
    emit('\t\t\tMARKETING_VERSION = 1.0;')
    emit('\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.cauchy.app;')
    emit('\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
    emit('\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
    emit('\t\t\tSWIFT_VERSION = 6.0;')
    emit('\t\t}; name = %s; };' % name)

emit("/* Begin XCBuildConfiguration section */")
# ENABLE_TESTABILITY is what makes `@testable import Cauchy` resolve; without
# it the test bundle cannot see the app module at all.
emit(f'\t\t{IDS["debug_p"]} /* Debug */ = {{ isa = XCBuildConfiguration; buildSettings = {{ ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; COPY_PHASE_STRIP = NO; DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES; ENABLE_STRICT_OBJC_MSGSEND = YES; GCC_DYNAMIC_NO_PIC = NO; MACOSX_DEPLOYMENT_TARGET = 26.0; MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE; ONLY_ACTIVE_ARCH = YES; SDKROOT = macosx; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; }}; name = Debug; }};')
emit(f'\t\t{IDS["release_p"]} /* Release */ = {{ isa = XCBuildConfiguration; buildSettings = {{ ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; COPY_PHASE_STRIP = NO; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; ENABLE_STRICT_OBJC_MSGSEND = YES; MACOSX_DEPLOYMENT_TARGET = 26.0; MTL_ENABLE_DEBUG_INFO = NO; SDKROOT = macosx; SWIFT_COMPILATION_MODE = wholemodule; }}; name = Release; }};')
target_settings(IDS["debug_t"], "Debug")
target_settings(IDS["release_t"], "Release")


def tests_settings(cid, name):
    emit(f'\t\t{cid} /* {name} */ = {{ isa = XCBuildConfiguration; buildSettings = {{')
    # The tests reach into the app with `@testable import Cauchy`, which only
    # links if the bundle is loaded by the app itself.
    emit('\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";')
    emit('\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/Cauchy.app/Contents/MacOS/Cauchy";')
    emit('\t\t\tCODE_SIGN_STYLE = Automatic;')
    emit('\t\t\tGENERATE_INFOPLIST_FILE = YES;')
    emit('\t\t\tMACOSX_DEPLOYMENT_TARGET = 26.0;')
    emit('\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.cauchy.app.tests;')
    emit('\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
    emit('\t\t\tSWIFT_VERSION = 6.0;')
    emit(f'\t\t}}; name = {name}; }};')


tests_settings(IDS["tests_debug"], "Debug")
tests_settings(IDS["tests_release"], "Release")
emit("/* End XCBuildConfiguration section */\n")

emit("/* Begin XCConfigurationList section */")
emit(f'\t\t{IDS["cl_project"]} = {{ isa = XCConfigurationList; buildConfigurations = ({IDS["debug_p"]}, {IDS["release_p"]},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
emit(f'\t\t{IDS["cl_target"]} = {{ isa = XCConfigurationList; buildConfigurations = ({IDS["debug_t"]}, {IDS["release_t"]},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
emit(f'\t\t{IDS["tests_cl"]} = {{ isa = XCConfigurationList; buildConfigurations = ({IDS["tests_debug"]}, {IDS["tests_release"]},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
emit("/* End XCConfigurationList section */")

emit("\n/* Begin XCLocalSwiftPackageReference section */")
emit(f'\t\t{IDS["swiftmath_pkg"]} /* XCLocalSwiftPackageReference "SwiftMath" */ = {{')
emit('\t\t\tisa = XCLocalSwiftPackageReference;')
emit('\t\t\trelativePath = Packages/SwiftMath;')
emit('\t\t};')
emit("/* End XCLocalSwiftPackageReference section */")

emit("\n/* Begin XCSwiftPackageProductDependency section */")
emit(f'\t\t{IDS["swiftmath_product"]} /* SwiftMath */ = {{')
emit('\t\t\tisa = XCSwiftPackageProductDependency;')
emit(f'\t\t\tpackage = {IDS["swiftmath_pkg"]} /* XCLocalSwiftPackageReference "SwiftMath" */;')
emit('\t\t\tproductName = SwiftMath;')
emit('\t\t};')
emit(f'\t\t{IDS["swiftterm_product"]} = {{isa = XCSwiftPackageProductDependency; package = {IDS["swiftterm_pkg"]}; productName = SwiftTerm; }};')
emit("/* End XCSwiftPackageProductDependency section */")
emit("/* Begin XCRemoteSwiftPackageReference section */")
emit(f'\t\t{IDS["swiftterm_pkg"]} = {{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/migueldeicaza/SwiftTerm.git"; requirement = {{kind = exactVersion; version = 1.10.0; }}; }};')
emit("/* End XCRemoteSwiftPackageReference section */")

emit("\t};")
emit(f'\trootObject = {IDS["project"]} /* Project object */;')
emit("}")

project_path = os.path.join(ROOT, "Cauchy.xcodeproj")
out = os.path.join(project_path, "project.pbxproj")
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")

# Written from scratch rather than patched: both the app and the test bundle
# are referenced by generated ids, and a scheme that still points at last run's
# ids silently builds nothing.
def buildable_reference(indent, target_id, buildable_name, blueprint_name):
    pad = " " * indent
    return "\n".join([
        f'{pad}<BuildableReference',
        f'{pad}   BuildableIdentifier = "primary"',
        f'{pad}   BlueprintIdentifier = "{target_id}"',
        f'{pad}   BuildableName = "{buildable_name}"',
        f'{pad}   BlueprintName = "{blueprint_name}"',
        f'{pad}   ReferencedContainer = "container:Cauchy.xcodeproj">',
        f'{pad}</BuildableReference>',
    ])


app_ref = buildable_reference(12, IDS["target"], "Cauchy.app", "Cauchy")
tests_ref = buildable_reference(12, IDS["tests_target"], "CauchyTests.xctest", "CauchyTests")

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
{app_ref}
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
{tests_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
{tests_ref}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
"""

scheme_path = os.path.join(ROOT, "Cauchy.xcodeproj", "xcshareddata", "xcschemes", "Cauchy.xcscheme")
os.makedirs(os.path.dirname(scheme_path), exist_ok=True)
with open(scheme_path, "w") as f:
    f.write(scheme)

print(f"Wrote {out}")
print(f"Target ID: {IDS['target']}")
print(f"Swift files: {len(swift_files)}")
print(f"Test files: {len(test_files)}")

resolve = subprocess.run(
    [
        "xcodebuild",
        "-resolvePackageDependencies",
        "-project",
        project_path,
    ],
    cwd=ROOT,
    capture_output=True,
    text=True,
)
if resolve.returncode != 0:
    print(resolve.stderr or resolve.stdout)
    raise SystemExit(resolve.returncode)
print("Resolved Swift package dependencies.")
