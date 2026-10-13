#!/usr/bin/env python3
"""Regenerate the committed Xcode project. Not needed to build or run the app."""
from pathlib import Path
import hashlib, json
root = Path(__file__).resolve().parent.parent
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(key, isa, **fields):
    value = uid(key); objects[value] = dict(isa=isa, **fields); return value

def configs(name, settings):
    ids = []
    for config in ['Debug', 'Release']:
        flags = dict(settings)
        flags.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if config == 'Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if config == 'Debug' else 'dwarf-with-dsym')
        if config == 'Debug': flags['ENABLE_TESTABILITY'] = 'YES'; flags['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        ids.append(add(name + config, 'XCBuildConfiguration', buildSettings=flags, name=config))
    return add(name+'configs', 'XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

corefiles = sorted((root/'Sources/YandexDiskCore').glob('*.swift'))
appfiles = sorted((root/'Sources/YandexDiskDownloader').glob('*.swift'))
testfiles = sorted((root/'Tests/YandexDiskCoreTests').glob('*.swift'))
def sources(name, paths):
    refs=[]; builds=[]
    for p in paths:
        ref=add(str(p.relative_to(root)), 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=str(p.relative_to(root)), sourceTree='SOURCE_ROOT')
        refs.append(ref); builds.append(add(name+p.name+'build', 'PBXBuildFile', fileRef=ref))
    group=add(name+'group', 'PBXGroup', children=refs, name=name, sourceTree='<group>')
    phase=add(name+'sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)
    return group,phase
cg,cp=sources('YandexDiskCore',corefiles); ag,ap=sources('YandexDiskDownloader',appfiles); tg,tp=sources('Tests',testfiles)
coreproduct=add('coreproduct','PBXFileReference',explicitFileType='archive.ar',path='libYandexDiskCore.a',sourceTree='BUILT_PRODUCTS_DIR')
appproduct=add('appproduct','PBXFileReference',explicitFileType='wrapper.application',path='Yandex Disk Downloader.app',sourceTree='BUILT_PRODUCTS_DIR')
testproduct=add('testproduct','PBXFileReference',explicitFileType='wrapper.cfbundle',path='YandexDiskCoreTests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
products=add('products','PBXGroup',children=[coreproduct,appproduct,testproduct],name='Products',sourceTree='<group>')
icon=add('icon','PBXFileReference',lastKnownFileType='image.icns',path='Resources/AppIcon.icns',sourceTree='SOURCE_ROOT')
plist=add('plist','PBXFileReference',lastKnownFileType='text.plist.xml',path='Resources/Info.plist',sourceTree='SOURCE_ROOT')
resources=add('resources','PBXGroup',children=[icon,plist],name='Resources',sourceTree='<group>')
iconbuild=add('iconbuild','PBXBuildFile',fileRef=icon)
rp=add('resourcesphase','PBXResourcesBuildPhase',buildActionMask=2147483647,files=[iconbuild],runOnlyForDeploymentPostprocessing=0)
main=add('main','PBXGroup',children=[cg,ag,tg,resources,products],sourceTree='<group>')
common=dict(MACOSX_DEPLOYMENT_TARGET='13.0',SWIFT_VERSION='5.0',SDKROOT='macosx',CLANG_ENABLE_MODULES='YES',CODE_SIGN_IDENTITY='-',CODE_SIGN_STYLE='Manual',ARCHS='$(ARCHS_STANDARD)',ONLY_ACTIVE_ARCH='NO')
coreconfig=configs('core',dict(common,PRODUCT_NAME='YandexDiskCore',PRODUCT_MODULE_NAME='YandexDiskCore',DEFINES_MODULE='YES',SKIP_INSTALL='YES',MACH_O_TYPE='staticlib'))
core=add('coretarget','PBXNativeTarget',buildConfigurationList=coreconfig,buildPhases=[cp],buildRules=[],dependencies=[],name='YandexDiskCore',productName='YandexDiskCore',productReference=coreproduct,productType='com.apple.product-type.library.static')
def dep(name):
    proxy=add(name+'proxy','PBXContainerItemProxy',containerPortal=uid('project'),proxyType=1,remoteGlobalIDString=core,remoteInfo='YandexDiskCore')
    return add(name+'dep','PBXTargetDependency',target=core,targetProxy=proxy)
def linking(name):
    bf=add(name+'corelink','PBXBuildFile',fileRef=coreproduct)
    return add(name+'frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[bf],runOnlyForDeploymentPostprocessing=0)
appconfig=configs('app',dict(common,PRODUCT_NAME='Yandex Disk Downloader',EXECUTABLE_NAME='YandexDiskDownloader',PRODUCT_BUNDLE_IDENTIFIER='io.github.ilnaz.YandexDiskDownloader',INFOPLIST_FILE='Resources/Info.plist',ENABLE_APP_SANDBOX='NO',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks']))
app=add('apptarget','PBXNativeTarget',buildConfigurationList=appconfig,buildPhases=[ap,linking('app'),rp],buildRules=[],dependencies=[dep('app')],name='YandexDiskDownloader',productName='Yandex Disk Downloader',productReference=appproduct,productType='com.apple.product-type.application')
testconfig=configs('test',dict(common,PRODUCT_NAME='YandexDiskCoreTests',PRODUCT_BUNDLE_IDENTIFIER='io.github.ilnaz.YandexDiskCoreTests',GENERATE_INFOPLIST_FILE='YES',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@loader_path/../Frameworks']))
test=add('testtarget','PBXNativeTarget',buildConfigurationList=testconfig,buildPhases=[tp,linking('test')],buildRules=[],dependencies=[dep('test')],name='YandexDiskCoreTests',productName='YandexDiskCoreTests',productReference=testproduct,productType='com.apple.product-type.bundle.unit-test')
project=add('project','PBXProject',attributes={'LastUpgradeCheck':'1600'},buildConfigurationList=configs('project',common),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','ru','Base'],mainGroup=main,productRefGroup=products,projectDirPath='',projectRoot='',targets=[core,app,test])
def render(value):
    if isinstance(value,dict): return '{\n'+''.join(json.dumps(str(k))+' = '+render(v)+';\n' for k,v in value.items())+'}'
    if isinstance(value,list): return '('+','.join(render(v) for v in value)+')'
    if isinstance(value,int): return str(value)
    return json.dumps(value,ensure_ascii=False)
p=root/'YandexDiskDownloader.xcodeproj'; p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n'+render(dict(archiveVersion=1,classes={},objectVersion=56,objects=objects,rootObject=project)))
scheme=p/'xcshareddata/xcschemes'; scheme.mkdir(parents=True,exist_ok=True)
def ref(target,name,product): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:YandexDiskDownloader.xcodeproj"/>'
(scheme/'YandexDiskDownloader.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app,'YandexDiskDownloader','Yandex Disk Downloader.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test,'YandexDiskCoreTests','YandexDiskCoreTests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app,'YandexDiskDownloader','Yandex Disk Downloader.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app,'YandexDiskDownloader','Yandex Disk Downloader.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated Xcode project with app, core library and XCTest target.')
