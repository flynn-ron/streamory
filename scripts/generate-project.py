#!/usr/bin/env python3
"""Generate the small dependency-free Xcode project without third-party tools."""
from pathlib import Path
import argparse, hashlib, json, math, os, struct, tempfile, zlib
root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--regenerate-icon', action='store_true', help='Recreate the code-drawn default icon')
args = parser.parse_args()
changed = []

def write_if_changed(path, content):
    data = content.encode('utf-8') if isinstance(content, str) else content
    if path.exists() and path.read_bytes() == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    # Xcode must never observe a truncated project or scheme while regenerating.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.' + path.name, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, path.stat().st_mode & 0o777 if path.exists() else 0o644)
        os.replace(temporary, path)
        changed.append(str(path.relative_to(root)))
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()

objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def put(name, text): objects[ident(name)] = text; return ident(name)
def quote(s): return json.dumps(str(s))
files = sorted((root / 'Streamory').rglob('*.swift'))
tests = sorted((root / 'StreamoryTests').glob('*.swift'))
refs=[]; sources=[]; testrefs=[]; testbuild=[]
for f in files + tests:
    relative = str(f.relative_to(root))
    ref = put(relative, f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = SOURCE_ROOT;}}')
    build = put(relative+'-build', f'{{isa = PBXBuildFile; fileRef = {ref};}}')
    (testrefs if f in tests else refs).append(ref)
    (testbuild if f in tests else sources).append(build)
resources=[]
for name, kind in [('Streamory/Assets.xcassets','folder.assetcatalog'),('Streamory/PrivacyInfo.xcprivacy','text.xml')]:
    ref=put(name, f'{{isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(name)}; sourceTree = SOURCE_ROOT;}}'); refs.append(ref)
    resources.append(put(name+'-build',f'{{isa = PBXBuildFile; fileRef = {ref};}}'))
app=put('app-product','{isa = PBXFileReference; explicitFileType = wrapper.application; path = Streamory.app; sourceTree = BUILT_PRODUCTS_DIR;}')
test=put('test-product','{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = StreamoryTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;}')
def phase(name,isa,items): return put(name,f'{{isa = {isa}; buildActionMask = 2147483647; files = ({",".join(items)}); runOnlyForDeploymentPostprocessing = 0;}}')
app_phases=[phase('app-sources','PBXSourcesBuildPhase',sources),phase('app-frameworks','PBXFrameworksBuildPhase',[]),phase('app-resources','PBXResourcesBuildPhase',resources)]
test_phases=[phase('test-sources','PBXSourcesBuildPhase',testbuild),phase('test-frameworks','PBXFrameworksBuildPhase',[]),phase('test-resources','PBXResourcesBuildPhase',[])]
def configs(name,base):
    ids=[]
    for mode in ['Debug','Release']:
        settings=dict(base)
        settings['SWIFT_OPTIMIZATION_LEVEL']='-Onone' if mode=='Debug' else '-O'
        if mode=='Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'; settings['ENABLE_TESTABILITY']='YES'
        ids.append(put(name+mode,'{isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {'+''.join(f'{k} = {quote(v)};' for k,v in settings.items())+'};}'))
    return put(name+'configlist',f'{{isa = XCConfigurationList; buildConfigurations = ({",".join(ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}}')
common={'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','SWIFT_STRICT_CONCURRENCY':'minimal','TARGETED_DEVICE_FAMILY':'1,2','CODE_SIGN_STYLE':'Automatic'}
project_config=configs('project',common)
app_config=configs('app',{'PRODUCT_BUNDLE_IDENTIFIER':'com.streamory.app','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'Streamory/Info.plist','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator'})
test_config=configs('test',{'PRODUCT_BUNDLE_IDENTIFIER':'com.streamory.app.tests','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Streamory.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Streamory','BUNDLE_LOADER':'$(TEST_HOST)','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
app_target=ident('app-target'); test_target=ident('test-target'); project=ident('project')
proxy=put('proxy',f'{{isa = PBXContainerItemProxy; containerPortal = {project}; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = Streamory;}}')
dep=put('dependency',f'{{isa = PBXTargetDependency; target = {app_target}; targetProxy = {proxy};}}')
put('app-target',f'{{isa = PBXNativeTarget; buildConfigurationList = {app_config}; buildPhases = ({",".join(app_phases)}); buildRules = (); dependencies = (); name = Streamory; productName = Streamory; productReference = {app}; productType = "com.apple.product-type.application";}}')
put('test-target',f'{{isa = PBXNativeTarget; buildConfigurationList = {test_config}; buildPhases = ({",".join(test_phases)}); buildRules = (); dependencies = ({dep}); name = StreamoryTests; productName = StreamoryTests; productReference = {test}; productType = "com.apple.product-type.bundle.unit-test";}}')
products=put('products',f'{{isa = PBXGroup; children = ({app},{test}); name = Products; sourceTree = "<group>";}}')
group=put('main-group',f'{{isa = PBXGroup; children = ({",".join(refs+testrefs+[products])}); sourceTree = "<group>";}}')
put('project',f'{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2630; TargetAttributes = {{{app_target} = {{CreatedOnToolsVersion = 26.3;}}; {test_target} = {{CreatedOnToolsVersion = 26.3; TestTargetID = {app_target};}};}};}}; buildConfigurationList = {project_config}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; knownRegions = (zh_CN,en,Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({app_target},{test_target});}}')
write_if_changed(root/'Streamory.xcodeproj/project.pbxproj', '// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{key} = {value};' for key,value in objects.items())+f'\n}}; rootObject = {project};}}\n')
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Streamory.app" BlueprintName="Streamory" ReferencedContainer="container:Streamory.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="StreamoryTests.xctest" BlueprintName="StreamoryTests" ReferencedContainer="container:Streamory.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Streamory.app" BlueprintName="Streamory" ReferencedContainer="container:Streamory.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="Streamory.app" BlueprintName="Streamory" ReferencedContainer="container:Streamory.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
write_if_changed(root/'Streamory.xcodeproj/xcshareddata/xcschemes/Streamory.xcscheme', scheme)
icon=root/'Streamory/Assets.xcassets/AppIcon.appiconset'
if args.regenerate_icon or not (icon/'AppIcon.png').exists():
    # Draw a code-native icon: flowing lines through a quiet dark field.
    width=1024
    rows=[]
    for y in range(width):
        row=bytearray()
        for x in range(width):
            line=min(abs(y-(420+i*90+70*math.sin((x-120)/180))) for i in range(3))
            stroke = line < 13 and 220 < x < 804
            c=(218,232,211) if stroke else (int(14+10*y/width),int(24+17*y/width),int(25+14*y/width))
            row.extend(c)
        rows.append(b'\0'+row)
    def chunk(kind,data): return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',width,width,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join(rows)))+chunk(b'IEND',b'')
    write_if_changed(icon/'AppIcon.png', png)
    write_if_changed(icon/'Contents.json', json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2))
print('Updated: ' + ', '.join(changed) if changed else 'Unchanged: project, scheme and icon preserved')
