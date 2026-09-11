import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const STATE_SOURCE = read('../Sources/State/DshState.swift')
const SEMVER_SOURCE = read('../Sources/Versions/DshSemanticVersion.swift')
const VERSION_MANAGER_SOURCE = read('../Sources/Versions/DshVersionManager.swift')
const SETTINGS_SOURCE = read('../Sources/SettingsUI/SettingsViewModel.swift')
const SETTINGS_VIEW_SOURCE = read('../Sources/SettingsUI/SettingsView.swift')
const VERSIONS_VIEW_SOURCE = read('../Sources/SettingsUI/VersionsTabView.swift')
const GENERAL_SOURCE = read('../Sources/SettingsUI/GeneralTabView.swift')
const PLUGIN_SOURCE = read('../Sources/Plugins/DshPluginManager.swift')
const COORDINATOR_SOURCE = read('../Sources/Plugins/DshPluginOperationCoordinator.swift')
const WINDOW_SOURCE = read('../Sources/MainWindow/MainWindowController.swift')
const UPSTREAM_COOKIE_SOURCE = read('../Sources/MainWindow/DshUpstreamCookieStore.swift')
const SERVICE_SOURCE = read('../Sources/Service/DshService.swift')
const GATE_SOURCE = read('../Sources/Service/DshAsyncOperationGate.swift')
const PROCESS_IO_SOURCE = read('../Sources/Service/DshProcessIO.swift')
const HOST_CONTROL = read('../assets/dsh-desktop-host/control.js')
const APP_SOURCE = read('../Sources/AppDelegate.swift')

test('runtime state persists active, previous, pending, and transaction phase', () => {
  assert.match(STATE_SOURCE, /public struct NpmRuntimeDescriptor: Codable, Equatable, Sendable/)
  assert.match(STATE_SOURCE, /public struct DshRuntimeState: Codable, Equatable, Sendable/)
  assert.match(STATE_SOURCE, /case alpha/)
  assert.match(STATE_SOURCE, /var active: NpmRuntimeDescriptor\?/)
  assert.match(STATE_SOURCE, /var previous: NpmRuntimeDescriptor\?/)
  assert.match(STATE_SOURCE, /var pending: NpmRuntimeDescriptor\?/)
  assert.match(STATE_SOURCE, /public var profile: DshAppProfile/)
  assert.match(STATE_SOURCE, /public var phase: DshRuntimeTransactionPhase/)
  assert.match(STATE_SOURCE, /public var webProfileSnapshotID: String\?/)
  assert.match(STATE_SOURCE, /public var dismissedAppVersion: String\?/)
  assert.match(STATE_SOURCE, /public var healthyStartCount: Int/)
  assert.match(STATE_SOURCE, /public var lastDiagnostic: String\?/)
  assert.match(STATE_SOURCE, /decodeIfPresent\(DshRuntimeState\.self, forKey: \.runtimeState\)/)
})

test('the app defaults to an isolated desktop Profile and exposes web as an explicit option', () => {
  assert.match(STATE_SOURCE, /public enum DshAppProfile:.*CaseIterable/)
  assert.match(STATE_SOURCE, /case desktop/)
  assert.match(STATE_SOURCE, /case web/)
  assert.match(STATE_SOURCE, /appProfile: DshAppProfile = \.desktop/)
  assert.match(STATE_SOURCE, /public struct DshProfileSwitchTransaction: Codable, Equatable, Sendable/)
  assert.match(STATE_SOURCE, /public enum DshProfileSwitchPhase: String, Codable, Sendable/)
  assert.match(STATE_SOURCE, /public var pendingProfileSwitch: DshProfileSwitchTransaction\?/)
  assert.match(STATE_SOURCE, /decodeIfPresent\(DshAppProfile\.self, forKey: \.appProfile\) \?\? \.desktop/)
  assert.match(SETTINGS_SOURCE, /public var appProfile: DshAppProfile/)
  assert.match(SETTINGS_SOURCE, /public func setAppProfile\(_ profile: DshAppProfile\)/)
  assert.match(SETTINGS_SOURCE, /appProfile == \.desktop/)
  assert.match(SETTINGS_SOURCE, /暂不允许升级 DSH Runtime/)
  assert.match(SETTINGS_SOURCE, /previous\.rawValue/)
  assert.match(GENERAL_SOURCE, /DSH Profile/)
  assert.match(GENERAL_SOURCE, /DshAppProfile\.allCases/)
  assert.match(GENERAL_SOURCE, /pickerStyle\(\.menu\)/)
  assert.match(GENERAL_SOURCE, /终端 dsh web 共享插件和依赖/)
  assert.match(VERSIONS_VIEW_SOURCE, /runtimeUpdatesAllowed/)
  assert.match(VERSIONS_VIEW_SOURCE, /web Profile 已禁用 Runtime 更新/)
  // The update-channel Picker is an ordinary settings mutation and remains
  // enabled during the confirmed cleanup window.
  assert.match(VERSIONS_VIEW_SOURCE, /disabled\(!runtimeUpdatesAllowed \|\| !viewModel\.pluginMutationsAllowed\)/)
  assert.match(VERSIONS_VIEW_SOURCE, /disabled\(viewModel\.isUpdatingRuntime \|\| !viewModel\.runtimeUpdateAllowed\)/)
  assert.match(PLUGIN_SOURCE, /profileDirectory\(for profile: DshAppProfile\)/)
  assert.match(PLUGIN_SOURCE, /public func removeDesktopHostArtifacts\([\s\S]*from profile: DshAppProfile[\s\S]*profileDirectory: URL\? = nil[\s\S]*\)/)
  assert.match(PLUGIN_SOURCE, /guard profile == \.web else/)
  assert.match(PLUGIN_SOURCE, /proc\.arguments = \["remove"\] \+ dependenciesToRemove/)
  assert.match(PLUGIN_SOURCE, /--config\.minimum-release-age=0/)
  assert.match(PLUGIN_SOURCE, /dsh-host-webserver/)
  assert.match(SERVICE_SOURCE, /profileName: context\.profileName/)
  assert.match(SERVICE_SOURCE, /public func prepareForProfileMutation\(context: DshLaunchContext\) async throws/)
  assert.match(SERVICE_SOURCE, /try context\.validate\(\)[\s\S]*waitForProfileMutationPort\(context\.port\)/)
  assert.match(SERVICE_SOURCE, /terminateRecordedProcess\(record\)/)
  assert.match(STATE_SOURCE, /case \.desktop: return "swift-desktop"/)
  assert.match(HOST_CONTROL, /SUPPORTED_PROFILES = new Set\(\["swift-desktop", "web"\]\)/)
  assert.match(WINDOW_SOURCE, /migrateLegacyDesktopProfileIfNeeded/)
})

test('Profile switches are recoverable across force-quit and commit only after a healthy restart', () => {
  assert.match(SETTINGS_SOURCE, /public func recoverPendingProfileSwitch\(\) async/)
  assert.match(SETTINGS_SOURCE, /public func retryPendingProfileSwitchCleanup\(for context: DshLaunchContext\) async/)
  assert.match(SETTINGS_SOURCE, /state\.pendingProfileSwitch == transaction/)
  assert.match(SETTINGS_SOURCE, /state\.appProfile = restoreProfile/)
  assert.match(SETTINGS_SOURCE, /removeDesktopHostArtifacts\([\s\S]*from: \.web[\s\S]*registry:/)
  assert.match(SETTINGS_SOURCE, /state\.pendingProfileSwitch = nil/)
  assert.match(SETTINGS_SOURCE, /DshProfileSwitchTransaction\(from: previous, to: profile\)/)
  assert.match(SETTINGS_SOURCE, /finalizingTransaction\.phase = \.finalizing/)
  assert.match(SETTINGS_SOURCE, /pendingProfileSwitch = transaction/)
  const profileSwitchBoundary = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('public func setAppProfile'),
    SETTINGS_SOURCE.indexOf('    /// Change the live Node policy', SETTINGS_SOURCE.indexOf('public func setAppProfile')),
  )
  assert.equal(
    (profileSwitchBoundary.match(/restartDshServiceWithAuthenticationRecoveryDuringOperation\(context: context\)/g) ?? []).length,
    2,
  )
  assert.doesNotMatch(profileSwitchBoundary, /restartDshServiceDuringOperation\(context: context\)/)
  assert.match(profileSwitchBoundary, /restartDshServiceWithAuthenticationRecoveryDuringOperation\(context: context\)[\s\S]*pendingProfileSwitch = cleanupError == nil \? nil : finalizingTransaction/)
  assert.match(profileSwitchBoundary, /restartDshServiceWithAuthenticationRecoveryDuringOperation\(context: context\)[\s\S]*pendingProfileSwitch = cleanupError == nil \? nil : transaction/)
  assert.match(SETTINGS_SOURCE, /Bridge cleanup is app-owned housekeeping|桥接清理是 App 自有清理/)
  assert.match(SETTINGS_SOURCE, /pendingProfileSwitch = cleanupError == nil \? nil : transaction/)
  assert.match(WINDOW_SOURCE, /retryPendingProfileSwitchCleanup\(for: context\)/)
  assert.match(WINDOW_SOURCE, /try await DshService\.shared\.prepareForProfileMutation\(context: context\)/)
  assert.match(APP_SOURCE, /await SettingsViewModel\.shared\.recoverPendingProfileSwitch\(\)/)
  assert.match(APP_SOURCE, /await DshService\.shared\.prepareForProfileMutation\(\)/)
  assert.ok(APP_SOURCE.indexOf('prepareForProfileMutation') < APP_SOURCE.indexOf('recoverPendingProfileSwitch'))
  assert.ok(APP_SOURCE.indexOf('recoverPendingProfileSwitch') < APP_SOURCE.indexOf('MainWindowController.shared.launch'))
})

test('runtime state migration prepares descriptors before taking the state lock', () => {
  assert.doesNotMatch(VERSION_MANAGER_SOURCE, /state\.runtimeState\.active\s*=\s*runtimeDescriptor\(/)
  assert.match(VERSION_MANAGER_SOURCE, /let descriptor = runtimeDescriptor\(version: first\)[\s\S]{0,180}DshStateManager\.shared\.update/)
})

test('runtime startup discovers auth mode from the validated ready URL', () => {
  assert.doesNotMatch(SERVICE_SOURCE, /DshRuntimeAuthContract/)
  assert.doesNotMatch(SERVICE_SOURCE, /unsupportedRuntimeAuthentication/)
  assert.doesNotMatch(PROCESS_IO_SOURCE, /expectedAuthMode/)
  assert.match(PROCESS_IO_SOURCE, /DshWebEndpoint\.parse\(url, expectedPort: expectedPort\)/)
  assert.match(UPSTREAM_COOKIE_SOURCE, /session\.endpoint\.authMode/)
})

test('npm runtime updates use SemVer ordering and a staging candidate', () => {
  assert.match(SEMVER_SOURCE, /public let prerelease: \[String\]/)
  assert.match(SEMVER_SOURCE, /public let buildMetadata: \[String\]/)
  assert.match(SEMVER_SOURCE, /if leftNumeric != rightNumeric/)
  assert.match(VERSION_MANAGER_SOURCE, /public func installCandidate\(/)
  assert.match(VERSION_MANAGER_SOURCE, /\["alpha", "rc"\]/)
  assert.match(VERSION_MANAGER_SOURCE, /public func discardInstalledVersion\(/)
  assert.match(VERSION_MANAGER_SOURCE, /public func cleanupUnreferencedVersions\(\)/)
  assert.match(VERSION_MANAGER_SOURCE, /let alignedFamily = try await resolveAlignedFamily\(version: version, registry: reg\)/)
  assert.match(VERSION_MANAGER_SOURCE, /activateWhenMissing: Bool = true/)
  assert.match(VERSION_MANAGER_SOURCE, /private func verifyNpmIntegrity\(/)
  assert.match(VERSION_MANAGER_SOURCE, /expectedIntegrity: String/)
  assert.doesNotMatch(VERSION_MANAGER_SOURCE, /public func uninstallVersion\(/)
  assert.match(STATE_SOURCE, /public static func begin\(/)
  assert.match(STATE_SOURCE, /phase: \.staging/)
  assert.match(STATE_SOURCE, /public static func beginVerification\(/)
  assert.match(STATE_SOURCE, /next\.phase = \.verifying/)
  assert.match(STATE_SOURCE, /public static func beginRollback\(/)
  assert.match(STATE_SOURCE, /next\.phase = \.rollingBack/)
  assert.match(SETTINGS_SOURCE, /DshRuntimeTransaction\.begin\(/)
  assert.match(SETTINGS_SOURCE, /DshRuntimeTransaction\.beginVerification\(/)
  assert.match(SETTINGS_SOURCE, /DshRuntimeTransaction\.beginRollback\(/)
  assert.match(SETTINGS_SOURCE, /DshRuntimeTransaction\.recordRollbackFailure\(/)
  assert.match(SETTINGS_SOURCE, /isRuntimeRecoveryPending/)
  assert.match(SETTINGS_SOURCE, /state\.runtimeState\.profile\.rawValue/)
  assert.match(GENERAL_SOURCE, /isRuntimeRecoveryPending/)
  assert.match(SETTINGS_SOURCE, /dismissedVersion = item\.version/)
  assert.match(SETTINGS_SOURCE, /dismissedAppVersion = currentAppVersion/)
  assert.match(SETTINGS_SOURCE, /dismissedVersion == latest/)
  assert.match(SETTINGS_SOURCE, /actually passes the normal startup health gate/)
  assert.match(SETTINGS_SOURCE, /withRuntimeOperation/)
  assert.match(SETTINGS_SOURCE, /recoverPendingRuntimeUpdate\(\) async/)
  assert.match(SETTINGS_SOURCE, /public func recordHealthyRuntimeStart\(for context: DshLaunchContext\) async/)
  assert.match(SETTINGS_SOURCE, /已自动恢复/)
})

test('runtime family installation fails closed and keeps npm registry metadata', () => {
  assert.match(VERSION_MANAGER_SOURCE, /guard alignedFamily\.missing\.isEmpty else/)
  assert.match(VERSION_MANAGER_SOURCE, /integrity: dist\?\["integrity"\] as\? String/)
  assert.match(VERSION_MANAGER_SOURCE, /public static func normalizedRegistry\(/)
  assert.match(PLUGIN_SOURCE, /private func registryArguments\(_ registry: String\)/)
  assert.match(PLUGIN_SOURCE, /registryArguments\(capturedRegistry\)/)
  assert.match(PLUGIN_SOURCE, /public func createWebProfileSnapshot\([\s\S]*\) async throws -> String/)
  assert.match(PLUGIN_SOURCE, /public func restoreWebProfileSnapshot\([\s\S]*_ id: String,[\s\S]*\) async throws/)
  assert.match(PLUGIN_SOURCE, /public func deleteWebProfileSnapshot\(_ id: String\) async throws/)
  assert.match(PLUGIN_SOURCE, /Task\.detached\(priority: \.utility\)/)
  assert.match(PLUGIN_SOURCE, /cloneDirectoryIfPossible/)
  assert.match(PLUGIN_SOURCE, /attemptedClone/)
  assert.match(PLUGIN_SOURCE, /removeItem\(at: destination\)/)
  assert.match(PLUGIN_SOURCE, /volumeAvailableCapacityForImportantUsage/)
  assert.match(PLUGIN_SOURCE, /DshProfileSnapshotProgress/)
})

test('version settings expose only one-way npm latest updates', () => {
  assert.match(VERSIONS_VIEW_SOURCE, /更新到/)
  assert.match(VERSIONS_VIEW_SOURCE, /viewModel\.updateToSelectedChannel\(\)/)
  assert.match(VERSIONS_VIEW_SOURCE, /DshRuntimeChannel\.next/)
  assert.match(VERSIONS_VIEW_SOURCE, /DshRuntimeChannel\.alpha/)
  assert.match(VERSIONS_VIEW_SOURCE, /pickerStyle\(\.menu\)/)
  assert.doesNotMatch(VERSIONS_VIEW_SOURCE, /selectVersion\(/)
  assert.doesNotMatch(VERSIONS_VIEW_SOURCE, /uninstallVersion\(/)
  assert.doesNotMatch(VERSIONS_VIEW_SOURCE, /安装此版本/)
})

test('the running Runtime channel is the recorded install source, not the picker', () => {
  // npm can serve one build from several dist-tags, so the badge shows what the
  // install recorded. Without a record the source stays unknown: the version
  // string is never used to guess a channel (round-5 P2).
  assert.match(STATE_SOURCE, /public let channel: DshRuntimeChannel\?/)
  assert.match(STATE_SOURCE, /public var activeChannel: DshRuntimeChannel\?/)
  assert.doesNotMatch(
    STATE_SOURCE,
    /DshRuntimeChannel\.inferred/,
    'the version-string inference must be gone, not just unused'
  )
  const activeChannel = STATE_SOURCE.slice(
    STATE_SOURCE.indexOf('public var activeChannel: DshRuntimeChannel?'),
    STATE_SOURCE.indexOf('/// Install source that can be recorded for an already installed Runtime')
  )
  assert.match(activeChannel, /active\?\.channel/)
  assert.match(activeChannel, /Unknown stays unknown/)
  // The install path records the channel while it builds the candidate.
  assert.match(
    SETTINGS_SOURCE,
    /NpmRuntimeDescriptor\(\s*version: item\.version,\s*registry: registry,\s*integrity: integrity,/
  )
  assert.match(SETTINGS_SOURCE, /channel: state\.runtimeState\.channel/)
  // A re-sync of an already installed Runtime must carry the source forward
  // instead of dropping it back to the version-string guess.
  assert.match(VERSION_MANAGER_SOURCE, /channel: state\.runtimeState\.active\?\.channel/)
  assert.match(VERSIONS_VIEW_SOURCE, /private var activeChannelName: String\?/)
  assert.match(VERSIONS_VIEW_SOURCE, /viewModel\.activeRuntimeChannel\?\.rawValue/)
  assert.doesNotMatch(
    VERSIONS_VIEW_SOURCE,
    /DshRuntimeChannel\.inferred/,
    'the card must not guess a channel from the version string'
  )
  assert.match(SETTINGS_SOURCE, /self\.activeRuntimeChannel = state\.runtimeState\.activeChannel/)

  // Legacy installs are backfilled only from an unambiguous single npm tag
  // from the *same* registry the Runtime was installed from, and only while no
  // Runtime/Profile transaction owns the descriptor.
  assert.match(STATE_SOURCE, /public static func installSourceBackfill\(/)
  assert.match(STATE_SOURCE, /catalogTagsForVersion tags: \[String\]/)
  assert.match(
    SETTINGS_SOURCE,
    /private func backfillActiveRuntimeChannel\(from catalog: \[DshVersionItem\], registry: String\)/
  )
  assert.match(SETTINGS_SOURCE, /DshRuntimeState\.installSourceBackfill\(/)
  assert.match(SETTINGS_SOURCE, /backfillActiveRuntimeChannel\(from: res\.versions, registry: registry\)/)
  const backfill = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('private func backfillActiveRuntimeChannel'),
    SETTINGS_SOURCE.indexOf('public func refreshPlugins()')
  )
  assert.match(backfill, /active\.channel == nil/)
  assert.match(backfill, /current\.channel == nil/)
  assert.match(
    backfill,
    /DshVersionManager\.normalizedRegistry\(registry\)[\s\S]{0,120}DshVersionManager\.normalizedRegistry\(active\.registry\)/,
    'tags from another registry must never be recorded as this Runtime\'s source'
  )
  assert.match(backfill, /DshVersionManager\.normalizedRegistry\(current\.registry\)/)
  assert.match(backfill, /isRuntimeStateSettled\(state\)/)
  assert.match(backfill, /loadFromState\(\)/)
  const settled = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('private func isRuntimeStateSettled'),
    SETTINGS_SOURCE.indexOf('public func refreshPlugins()')
  )
  assert.match(settled, /state\.runtimeState\.phase == \.idle/)
  assert.match(settled, /state\.runtimeState\.pending == nil/)
  assert.match(settled, /state\.pendingProfileSwitch == nil/)
  const predicate = STATE_SOURCE.slice(
    STATE_SOURCE.indexOf('public static func installSourceBackfill'),
    STATE_SOURCE.indexOf('public static let `default` = DshRuntimeState()')
  )
  assert.match(predicate, /active\.channel == nil/)
  assert.match(predicate, /tags\.count == 1/)

  const runtimeCard = VERSIONS_VIEW_SOURCE.slice(
    VERSIONS_VIEW_SOURCE.indexOf('"DSH Runtime"'),
    VERSIONS_VIEW_SOURCE.indexOf('if viewModel.isInstallingVersion')
  )
  assert.match(runtimeCard, /sourceDescription/)
  assert.doesNotMatch(runtimeCard, /channelName/)
  // The card text itself has to be built from the recorded install source, and
  // an unrecorded source must not be dressed up as a channel.
  assert.match(
    VERSIONS_VIEW_SOURCE,
    /private var sourceDescription: String \{[\s\S]{0,200}activeChannelName/
  )
  assert.match(VERSIONS_VIEW_SOURCE, /来源：npm Registry · 通道：未记录/)
})

test('plugin install asks before bypassing the minimum release age policy', () => {
  assert.match(PLUGIN_SOURCE, /public func addPlugin\([\s\S]*spec: String,[\s\S]*ignoringMinimumReleaseAge: Bool = false[\s\S]*\) async throws/)
  assert.match(PLUGIN_SOURCE, /MINIMUM_RELEASE_AGE_VIOLATION/)
  assert.match(PLUGIN_SOURCE, /if ignoringMinimumReleaseAge[\s\S]*--config\.minimum-release-age=0/)
  assert.match(PLUGIN_SOURCE, /let stdout = Pipe\(\)[\s\S]*let stderr = Pipe\(\)[\s\S]*processOutput\(result\)/)
  assert.match(SETTINGS_SOURCE, /pendingPluginInstallSpec/)
  assert.match(SETTINGS_SOURCE, /confirmPendingPluginInstall\(\)/)
  assert.match(SETTINGS_SOURCE, /isMinimumReleaseAgeViolation\(error\)/)
  assert.match(SETTINGS_VIEW_SOURCE, /confirmationDialog\(/)
  assert.match(SETTINGS_VIEW_SOURCE, /继续安装插件？/)
  assert.match(SETTINGS_SOURCE, /不会修改全局 pnpm 配置/)
})

test('plugin update checks use pnpm-compatible registry and release-age handling', () => {
  const start = PLUGIN_SOURCE.indexOf('public func checkOutdatedPlugins()')
  const end = PLUGIN_SOURCE.indexOf('    /// Add a plugin by name or npm specifier.', start)
  const checkSource = PLUGIN_SOURCE.slice(start, end)

  assert.match(checkSource, /"outdated",\s*"--format",\s*"json"/)
  assert.match(checkSource, /--config\.minimum-release-age=0/)
  assert.match(checkSource, /env\["npm_config_registry"\]/)
  assert.match(checkSource, /runProcess\(proc, stdout: stdout, stderr: stderr\)/)
  assert.match(checkSource, /result\.status == 0 \|\| result\.status == 1/)
  assert.match(checkSource, /检测插件更新失败（退出码/)
})

test('plugin updates ask before bypassing the minimum release age policy', () => {
  assert.match(PLUGIN_SOURCE, /public enum DshPendingPluginUpdate: Equatable, Sendable/)
  assert.match(PLUGIN_SOURCE, /public func updatePlugin\([\s\S]*name: String,[\s\S]*ignoringMinimumReleaseAge: Bool = false/)
  assert.match(PLUGIN_SOURCE, /public func updateAllPlugins\([\s\S]*ignoringMinimumReleaseAge: Bool = false/)
  assert.match(PLUGIN_SOURCE, /var arguments = \["update", name, "--latest"\][\s\S]*if ignoringMinimumReleaseAge[\s\S]*--config\.minimum-release-age=0/)
  assert.match(PLUGIN_SOURCE, /var arguments = \["update"\] \+ pluginNames \+ \["--latest"\] \+ Self\.thinLinkFetchArguments[\s\S]*if ignoringMinimumReleaseAge[\s\S]*--config\.minimum-release-age=0/)
  assert.match(SETTINGS_SOURCE, /pendingPluginUpdate/)
  assert.match(SETTINGS_SOURCE, /confirmPendingPluginUpdate\(\)/)
  assert.match(SETTINGS_SOURCE, /cancelPendingPluginUpdate\(\)/)
  assert.match(SETTINGS_SOURCE, /pendingPluginUpdateMessage/)
  assert.match(SETTINGS_SOURCE, /startPluginUpdate\(name: name, ignoringMinimumReleaseAge: false\)/)
  assert.match(SETTINGS_SOURCE, /startPluginUpdateAll\(ignoringMinimumReleaseAge: false\)/)
  assert.ok(SETTINGS_SOURCE.includes('正在更新插件（共 \\(count) 个）…'))
  assert.match(SETTINGS_SOURCE, /插件更新完成，正在重启 DSH 服务…/)
  assert.ok(!SETTINGS_SOURCE.includes('正在更新插件（0/\\(count)）…'))
  assert.match(SETTINGS_SOURCE, /if !ignoringMinimumReleaseAge,[\s\S]*isMinimumReleaseAgeViolation\(error\)/)
  assert.match(SETTINGS_VIEW_SOURCE, /继续更新插件？/)
  assert.match(SETTINGS_VIEW_SOURCE, /confirmPendingPluginUpdate\(\)/)
  assert.match(SETTINGS_VIEW_SOURCE, /pendingPluginUpdateMessage/)
})

test('runtime confirmation waits for the rendered Web UI after navigation', () => {
  assert.match(WINDOW_SOURCE, /try await (?:self\.)?waitForWebUIReady\(\)/)
  assert.match(WINDOW_SOURCE, /try await verifyRuntimeHealth\(session: authenticatedSession, upstreamCookies: upstreamCookies\)/)
  assert.match(WINDOW_SOURCE, /匿名 loopback/)
  assert.match(WINDOW_SOURCE, /verifyBrowserAccessBoundary/)
  assert.match(WINDOW_SOURCE, /verifyLANAccessBoundary/)
  assert.match(GATE_SOURCE, /final class DshAsyncOperationGate/)
  assert.match(SERVICE_SOURCE, /startOperationGate\.acquire\(\)/)
  assert.match(WINDOW_SOURCE, /DshAsyncOperationGate/)
  assert.match(WINDOW_SOURCE, /restartDshServiceDuringOperation/)
  assert.match(WINDOW_SOURCE, /createWebProfileSnapshot/)
  assert.match(WINDOW_SOURCE, /await DshService\.shared\.stopAndWait\(\)/)
  assert.match(WINDOW_SOURCE, /restoreWebProfileSnapshot\([\s\S]*profile: context\.profile[\s\S]*profileDirectory: context\.profileDirectory/)
  assert.match(WINDOW_SOURCE, /context\.purpose == \.runtimeRollback[\s\S]*context\.transactionID == runtimeState\.transactionID[\s\S]*context\.profile == runtimeState\.profile/)
  assert.match(WINDOW_SOURCE, /private func beginWebUIReadinessCheck\(/)
  assert.match(WINDOW_SOURCE, /pendingWebUINavigation/)
  assert.match(WINDOW_SOURCE, /completeWebUIReadiness\(\.success\(\(\)\)\)/)
  assert.match(WINDOW_SOURCE, /webView\(_ webView: WKWebView, didFinish navigation:/)
})

test('runtime update policy defaults to notify and labels failure stages', () => {
  assert.match(STATE_SOURCE, /updatePolicy: DshRuntimeUpdatePolicy = \.notify/)
  assert.match(STATE_SOURCE, /autoFollowLatest: Bool = false/)
  assert.match(STATE_SOURCE, /self\.autoFollowLatest = runtimeState\.updatePolicy == \.automaticStable/)
  assert.match(STATE_SOURCE, /self\.updatePolicy = \.notify/)
  assert.match(SETTINGS_SOURCE, /DshRuntimeUpdateFailure/)
  assert.match(SETTINGS_SOURCE, /candidate Runtime/)
  assert.match(SETTINGS_SOURCE, /启动或健康检查失败/)
  assert.match(SETTINGS_SOURCE, /public var runtimeChannel: DshRuntimeChannel/)
  assert.match(SETTINGS_SOURCE, /public var alphaVersion: String\?/)
  assert.match(SETTINGS_SOURCE, /public func updateToSelectedChannel\(\)/)
  assert.match(SETTINGS_SOURCE, /state\.runtimeState\.channel = runtimeChannel/)
  assert.match(SETTINGS_SOURCE, /catalogRequestGeneration/)
  assert.match(SETTINGS_SOURCE, /availableVersions = \[\]/)
  assert.doesNotMatch(GENERAL_SOURCE, /更新通道：next/)
  assert.doesNotMatch(GENERAL_SOURCE, /自动更新已开启/)
  assert.match(VERSIONS_VIEW_SOURCE, /自动更新已开启/)
  assert.match(VERSIONS_VIEW_SOURCE, /automaticUpdatesAllowed/)
  assert.match(VERSIONS_VIEW_SOURCE, /切回 stable（latest）后才可以重新启用/)
  // Auto-follow is also a settings preference, while an actual Runtime
  // install must use the stricter runtimeUpdateAllowed gate.
  assert.match(VERSIONS_VIEW_SOURCE, /disabled\(!automaticUpdatesAllowed \|\| !viewModel\.pluginMutationsAllowed\)/)
  assert.match(SETTINGS_SOURCE, /public var runtimeUpdateAllowed: Bool/)
  assert.match(SETTINGS_SOURCE, /DshRuntimeMutationGate\.allowsPluginMutation\(state\)/)
  assert.match(SETTINGS_SOURCE, /DshRuntimeMutationGate\.allowsRuntimeUpdate\(state\)/)
  assert.match(SETTINGS_SOURCE, /runtimeChannel != \.latest[\s\S]*autoFollowLatest/)
  assert.match(VERSIONS_VIEW_SOURCE, /channelDescription/)
  assert.match(VERSIONS_VIEW_SOURCE, /runtimeChannelSelection/)

  // Round-3 T1/T4: package-tree writes (plugin install/update/remove) and
  // Profile switches require a settled Runtime, while the general settings
  // gate above stays open during the confirmed cleanup window.
  assert.match(STATE_SOURCE, /public static func allowsProfileTreeMutation/)
  assert.match(
    SETTINGS_SOURCE,
    /public var pluginWritesAllowed: Bool \{[\s\S]{0,400}allowsProfileTreeMutation\(DshStateManager\.shared\.current\)/
  )
  const setAppProfile = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('public func setAppProfile(_ profile: DshAppProfile)'),
    SETTINGS_SOURCE.indexOf('public func setBrowserAccessEnabled(')
  )
  assert.ok(setAppProfile.length > 0, 'setAppProfile must exist')
  assert.match(
    setAppProfile,
    /guard DshRuntimeMutationGate\.allowsProfileTreeMutation\(state\) else \{/,
    'Profile switching must wait for a settled Runtime'
  )
  const saveGeneral = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('public func saveGeneralSettings()'),
    SETTINGS_SOURCE.indexOf('public func setAppProfile(')
  )
  assert.ok(saveGeneral.length > 0, 'saveGeneralSettings must exist')
  assert.match(
    saveGeneral,
    /let profileMutationAllowed = DshRuntimeMutationGate[\s\S]{0,80}allowsProfileTreeMutation\(stateBeforeSave\)/,
    'the settings persistence boundary must not persist a Profile change during confirmed cleanup'
  )
  assert.match(SETTINGS_SOURCE, /新 Runtime 已确认但尚未结算/)
})

test('R12 keeps displaced Profile trees behind a durable completion proof', () => {
  // State shape: the debt record and its decision rule.
  assert.match(STATE_SOURCE, /public struct DshProfileRestoreCleanup/)
  assert.match(STATE_SOURCE, /public var pendingProfileRestoreCleanups: \[DshProfileRestoreCleanup\]/)
  assert.match(
    STATE_SOURCE,
    /case pendingProfileRestoreCleanup$/m,
    'the single-slot legacy key must stay decodable'
  )
  assert.match(STATE_SOURCE, /public static func mayReclaim\(/)
  assert.match(STATE_SOURCE, /cleanup\.completed\s*\n\s*&& cleanup\.hasWellFormedDisplacedName/)
  // Round-6: a directory merely named `profiles` is not evidence. The record
  // must sit directly inside a Profile root this app creates.
  assert.match(STATE_SOURCE, /public func displacedRootIsTrusted\(_ trustedRoots: \[URL\]\) -> Bool/)
  assert.match(
    STATE_SOURCE,
    /cleanup\.displacedRootIsTrusted\(trustedProfilesRoots\)\s*\n\s*&& canonicalProfileIsRealDirectory/
  )
  assert.match(STATE_SOURCE, /trustedProfilesRoots: \[URL\]/)
  // The version-string inference must stay gone: unknown is reported as unknown.
  assert.doesNotMatch(STATE_SOURCE, /hasWellFormedDisplacedName[\s\S]{0,300}lastPathComponent == "profiles"/)

  // Round-4 R12: the decision is derived from the record itself. The record
  // lives in Application Support, which every DSH_HOME shares, so the current
  // home's canonical Profile must never authorise deleting this tree.
  assert.match(STATE_SOURCE, /public var profilesRootURL: URL \{\s*\n\s*displacedURL\.deletingLastPathComponent\(\)/)
  assert.match(STATE_SOURCE, /public var canonicalProfileURL: URL \{\s*\n\s*profilesRootURL\.appendingPathComponent\(profile\.runtimeProfileName/)
  assert.match(STATE_SOURCE, /public var hasWellFormedDisplacedName: Bool \{/)
  assert.doesNotMatch(
    SETTINGS_SOURCE,
    /DshLaunchContext\.profileDirectory\(for: cleanup\.profile\)/,
    'reclamation must not derive the canonical Profile from the current DSH_HOME'
  )

  // The deletion entry point re-validates the identity it was handed: the
  // recorded path is user-writable state, so a mismatch must never turn a
  // startup pass into an arbitrary recursive delete.
  assert.match(PLUGIN_SOURCE, /expectedSnapshotID: String/)
  assert.match(PLUGIN_SOURCE, /expectedParent: URL/)
  assert.match(PLUGIN_SOURCE, /static func isDisplacedProfileRestoreName\(_ name: String, snapshotID: String\)/)
  assert.match(PLUGIN_SOURCE, /UUID\(uuidString: snapshotID\) != nil/)
  assert.match(PLUGIN_SOURCE, /func removeDisplacedProfileTree\([\s\S]{0,160}expectedSnapshotID/)
  assert.match(
    PLUGIN_SOURCE,
    /deletingLastPathComponent\(\)\.path\s*\n\s*== expectedParent\.standardizedFileURL\.path/,
    'the deletion entry point must verify the tree is inside the expected Profile root'
  )

  // The debt is recorded before a restore can displace the live Profile, and
  // settled afterwards with the proof the restore itself cannot write.
  const begin = SETTINGS_SOURCE.indexOf('public func beginProfileRestoreCleanup(')
  const finish = SETTINGS_SOURCE.indexOf('public func finishProfileRestoreCleanup(')
  const retry = SETTINGS_SOURCE.indexOf('public func retryPendingProfileRestoreCleanup()')
  assert.ok(begin > 0 && finish > begin && retry > finish, 'the cleanup lifecycle must exist')

  const beginBody = SETTINGS_SOURCE.slice(begin, finish)
  assert.match(beginBody, /completed: false/, 'the debt starts unproven')
  assert.match(
    beginBody,
    /pendingProfileRestoreCleanups\.append\(record\)/,
    'a new debt must be appended, never overwrite another one'
  )
  assert.match(
    beginBody,
    /removeAll \{\s*\n\s*\$0\.matches\(profile: profile, snapshotID: snapshotID\)/,
    're-recording the same identity restarts its completion proof'
  )
  const finishBody = SETTINGS_SOURCE.slice(finish, retry)
  assert.match(finishBody, /completed = true/, 'the proof is written after the restore')
  assert.match(finishBody, /pendingProfileRestoreCleanups\.remove\(at: index\)/, 'a clean restore clears the debt')
  assert.match(finishBody, /matches\(profile: profile, snapshotID: snapshotID\)/, 'the settle must target its own record')

  const retryBody = SETTINGS_SOURCE.slice(retry, SETTINGS_SOURCE.indexOf('/// Finish a rollback that was left pending'))
  assert.match(
    retryBody,
    /for cleanup in state\.pendingProfileRestoreCleanups/,
    'every recorded debt must be considered'
  )
  assert.match(retryBody, /DshPluginManager\.isRealDirectory\(/)
  assert.match(retryBody, /DshPluginManager\.isRealDirectory\(at: cleanup\.profilesRootURL\)/)
  assert.match(retryBody, /trustedProfileRoots/)
  assert.match(retryBody, /expectedParent: cleanup\.profilesRootURL/)
  const trustedRoots = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('private static var trustedProfileRoots'),
    SETTINGS_SOURCE.indexOf('public func retryPendingProfileRestoreCleanup()')
  )
  assert.match(
    trustedRoots,
    /DshLaunchContext\.profileDirectory\(for: \.desktop\)[\s\S]{0,120}deletingLastPathComponent\(\)/,
    'the trusted root must be the app-owned `profiles` directory of the configured DSH home'
  )
  assert.doesNotMatch(
    trustedRoots,
    /displacedPath/,
    'the trusted root must not be derived from the untrusted record'
  )
  assert.ok(
    retryBody.indexOf('mayReclaim(') < retryBody.indexOf('removeDisplacedProfileTree('),
    'the reclamation pass must require the proof before deleting anything'
  )
  assert.ok(
    retryBody.indexOf('removeDisplacedProfileTree(') < retryBody.indexOf('pendingProfileRestoreCleanups.removeAll'),
    'the debt is cleared only after the tree is really gone'
  )
  assert.match(retryBody, /guard reclaimed else/, 'a failed reclamation keeps the debt and reports it')

  // Both restore call sites own the record lifecycle.
  assert.ok(
    (SETTINGS_SOURCE.match(/beginProfileRestoreCleanup\(/g) || []).length >= 2,
    'the reset path and the debt helper itself must call begin'
  )
  assert.match(WINDOW_SOURCE, /beginProfileRestoreCleanup\(/)
  assert.match(WINDOW_SOURCE, /finishProfileRestoreCleanup\(/)
  assert.match(
    WINDOW_SOURCE,
    /finishProfileRestoreCleanup\([\s\S]{0,160}snapshotID: snapshotID/,
    'the settle must carry the record identity'
  )

  // Round-4 (resume ordering): both restore implementations must keep an
  // existing displaced leftover until the replacement content has been
  // verified and installed. Deleting it first destroyed the only complete copy
  // whenever the resumed restore then failed.
  assert.equal(
    (PLUGIN_SOURCE.match(/let resumeWithLeftover = snapshotHasContent/g) || []).length,
    2,
    'the Profile restore and the P01 restore must share the resume rule'
  )

  // The startup pass runs after the retained-snapshot cleanup and before the
  // first launch.
  assert.match(APP_SOURCE, /retryRetainedWebProfileSnapshotCleanup\(\)[\s\S]{0,400}retryPendingProfileRestoreCleanup\(\)/)
  assert.ok(
    APP_SOURCE.indexOf('retryPendingProfileRestoreCleanup') < APP_SOURCE.indexOf('MainWindowController.shared.launch'),
    'the reclamation pass must run before the launch decision'
  )
})

test('startup recovery restores a Profile at most once and retries retained cleanup', () => {
  assert.match(APP_SOURCE, /await SettingsViewModel\.shared\.recoverPendingRuntimeUpdate\(\)/)
  assert.match(APP_SOURCE, /await SettingsViewModel\.shared\.retryRetainedWebProfileSnapshotCleanup\(\)/)
  assert.ok(APP_SOURCE.indexOf('recoverPendingRuntimeUpdate') < APP_SOURCE.indexOf('MainWindowController.shared.launch'))
  assert.match(SETTINGS_SOURCE, /public func retryRetainedWebProfileSnapshotCleanup\(\) async/)
  assert.match(WINDOW_SOURCE, /try await withRuntimeOperation \{[\s\S]*await SettingsViewModel\.shared\.recordHealthyRuntimeStart\(for: context\)/)
  const rollbackRecovery = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('case .rollback'),
    SETTINGS_SOURCE.indexOf('case .reset')
  )
  assert.doesNotMatch(rollbackRecovery, /restoreWebProfileSnapshot/)
})

test('healthy-start cleanup validates the persisted count before committing', () => {
  const cleanup = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('public func recordHealthyRuntimeStart(for context: DshLaunchContext)'),
    SETTINGS_SOURCE.indexOf('/// Retry a snapshot deletion')
  )
  assert.ok(
    (cleanup.match(/healthyStartCount == nextCount - 1/g) || []).length >= 1,
    'the commit guard must compare against the persisted pre-commit count'
  )
  assert.match(cleanup, /healthyStartCount = 0[\s\S]*phase = \.idle/)
})

test('round-3 fixes keep their ordering and fail-closed invariants', () => {
  // T8: the confirmed settle must commit idle (retaining the snapshot id as
  // cleanup debt) BEFORE deleting the snapshot or discarding the previous
  // Runtime. Deleting first would leave durable state claiming a rollback is
  // available while its resources are gone, and the new "roll back to the
  // previous Runtime" action would then hard-block on -32.
  const healthyStart = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('public func recordHealthyRuntimeStart(for context: DshLaunchContext)'),
    SETTINGS_SOURCE.indexOf('/// Retry a snapshot deletion')
  )
  assert.ok(healthyStart.length > 0, 'the healthy-start settle must exist')
  const idleCommit = healthyStart.indexOf('state.runtimeState.phase = .idle')
  assert.ok(idleCommit >= 0, 'the healthy-start settle must commit idle')
  assert.ok(
    idleCommit < healthyStart.indexOf('deleteWebProfileSnapshot('),
    'the idle commit must precede the retained-snapshot deletion'
  )
  assert.ok(
    idleCommit < healthyStart.indexOf('discardInstalledVersion('),
    'the idle commit must precede discarding the previous Runtime'
  )
  assert.match(healthyStart, /webProfileSnapshotID = snapshotID/)
  assert.match(healthyStart, /retryRetainedWebProfileSnapshotCleanup\(\)/)

  // T7: resetting an abandoned transaction is one pure transition that also
  // clears the transaction owner, so the mutation gates reopen in-session.
  assert.match(STATE_SOURCE, /public static func settleAbandoned/)
  assert.match(SETTINGS_SOURCE, /DshRuntimeTransaction\.settleAbandoned\(/)

  // T2: selection repair must never settle a transaction that still owns
  // usable recovery evidence.
  assert.match(
    VERSION_MANAGER_SOURCE,
    /guard !hasRecoverableRuntimeTransaction\(state\.runtimeState\) else \{/
  )
  assert.match(VERSION_MANAGER_SOURCE, /private func hasRecoverableRuntimeTransaction\(/)

  // Round-3 T5 (symlink escape through the orphan sweeps) was disproven: both
  // sweeps enumerate with `contentsOfDirectory(at:includingPropertiesForKeys:
  // options:)`, which refuses a symlinked directory, and removal of a link
  // entry deletes the link, not its target. The behavioral guard lives in
  // swift-plugin-operation-harness.swift (`snapshot-sweep-symlink-guard`).

  // T6: every P01 entry point (validate/adopt/recover/restore + snapshot
  // create) rejects a dangling Profile symlink that `fileExists` cannot see.
  assert.ok(
    (COORDINATOR_SOURCE.match(/DshPluginManager\.isSymbolicLink\(at:/g) || []).length >= 3,
    'validate, adopt and recover/restore must all use the lstat symlink check'
  )
  assert.match(
    PLUGIN_SOURCE,
    /if Self\.isSymbolicLink\(at: profileURL\) \{\s*\n\s*throw DshPluginOperationError\.unsafeProfileDirectory/
  )

  // T9: the legacy Profile/transaction migration runs inside the throwing
  // startup chain, not as a discarded write in loadFromState.
  const loadFromState = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('public func loadFromState()'),
    SETTINGS_SOURCE.indexOf('private func syncRuntimeRecoveryState()')
  )
  assert.ok(loadFromState.length > 0, 'loadFromState must exist')
  assert.doesNotMatch(
    loadFromState,
    /state\.appProfile = transactionProfile/,
    'the legacy owner migration must not run as a discarded write in loadFromState'
  )
  const profileSwitchRecovery = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('public func recoverPendingProfileSwitch() async throws {'),
    SETTINGS_SOURCE.indexOf('public func retryPendingProfileSwitchCleanup(')
  )
  assert.match(
    profileSwitchRecovery,
    /updateOrThrow \{ state in[\s\S]*state\.appProfile = repairTarget/,
    'the repair must write the owner Profile inside the throwing chain'
  )
  // Round-4 T9: the repair must cover *every* open, owned transaction, not
  // only one with a pending descriptor. A confirmed transaction has already
  // cleared `pending`, and skipping the repair there left the app locked: the
  // health count refuses to settle a transaction started in the wrong Profile,
  // the Profile switch is gated on idle, and the Runtime rollback action only
  // applies to desktop.
  assert.match(STATE_SOURCE, /public enum DshRuntimeTransactionOwnership/)
  assert.match(STATE_SOURCE, /public static func profileRepairTarget\(/)
  assert.match(STATE_SOURCE, /guard runtime\.phase != \.idle, hasOwnerEvidence else \{ return nil \}/)
  assert.doesNotMatch(
    STATE_SOURCE,
    /guard runtime\.pending != nil,\s*\n\s*runtime\.transactionID != nil else \{ return nil \}/,
    'the repair must not require a pending descriptor'
  )
  assert.match(
    profileSwitchRecovery,
    /DshRuntimeTransactionOwnership\.profileRepairTarget\(/,
    'recoverPendingProfileSwitch must ask the ownership rule'
  )
  assert.match(profileSwitchRecovery, /hasPendingProfileSwitch: existing\.pendingProfileSwitch != nil/)
})

test('round-2 fixes keep their fail-closed ordering and invariants', () => {
  // R4: the recovered-rollback settle must commit the settled state before
  // deleting the retained web Profile snapshot; otherwise a kill in between
  // leaves durable state referencing a deleted snapshot and every later
  // launch fails with -32 without any recovery action.
  const finalize = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf(
      'public func finalizeRecoveredRuntimeAfterSuccessfulStart(for context: DshLaunchContext)'
    ),
    SETTINGS_SOURCE.indexOf('private func runRuntimeUpdate(')
  )
  assert.ok(finalize.length > 0, 'the recovered-rollback settle must exist')
  assert.ok(
    finalize.indexOf('DshRuntimeTransaction.finishRollback(') <
      finalize.indexOf('deleteWebProfileSnapshot('),
    'the rollback commit must precede the retained-snapshot deletion'
  )
  assert.match(finalize, /retainedWebProfileSnapshotID: snapshotID/)
  assert.match(finalize, /retryRetainedWebProfileSnapshotCleanup\(\)/)

  // R1: only a settled (`idle`) or confirmed-cleanup state may re-sync
  // `active`. The previous `pending == nil || phase == .idle || ...`
  // disjunction collapsed an interrupted user-initiated rollback (which has
  // previous/transactionID but no pending) to idle.
  assert.doesNotMatch(
    VERSION_MANAGER_SOURCE,
    /pending == nil \|\| state\.runtimeState\.phase == \.idle/
  )
  assert.match(
    VERSION_MANAGER_SOURCE,
    /guard state\.runtimeState\.pending == nil,\s*\n\s*phase == \.idle \|\| phase == \.confirmed else \{ return \}/
  )
  assert.match(STATE_SOURCE, /public static func repairIdleTransactionResidue/)
  assert.match(SETTINGS_SOURCE, /repairIdleTransactionResidue/)

  // R5 + T10: an already-cancelled acquire fails immediately instead of being
  // queued; a queued cancellation is decided under the gate lock; and a
  // cancellation that loses the hand-off race still fails the acquire after
  // releasing the lock it just received.
  assert.match(
    GATE_SOURCE,
    /if Task\.isCancelled \{\s*\n\s*resumeCancelled = true/
  )
  assert.match(
    GATE_SOURCE,
    /if resumeCancelled \{\s*\n\s*continuation\.resume\(throwing: CancellationError\(\)\)/
  )
  assert.match(GATE_SOURCE, /case handedOff/)
  assert.match(GATE_SOURCE, /waiter\.state = \.cancelled/)
  assert.match(GATE_SOURCE, /next\?\.state = \.handedOff/)
  assert.match(
    GATE_SOURCE,
    /if Task\.isCancelled \{\s*\n\s*release\(\)\s*\n\s*throw CancellationError\(\)/
  )
  assert.doesNotMatch(
    GATE_SOURCE,
    /Task\.isCancelled \{\s*\n\s*cancelled\.mark\(\)\s*\n\s*waiters\.append/
  )

  // R10: the automatic service restore after a failed plugin operation must
  // treat a corrupt durable record as "do not restart".
  assert.match(
    SETTINGS_SOURCE,
    /guard !DshPluginOperationCoordinator\.shared\.hasPersistedOperationRecord/
  )

  // R2: the staging sweep must enumerate hidden entries (every target is
  // dot-prefixed) and validate the app-generated UUID suffix.
  const sweep = PLUGIN_SOURCE.slice(
    PLUGIN_SOURCE.indexOf('public func cleanupOrphanedStagingDirectories()'),
    PLUGIN_SOURCE.indexOf('static func isAppGeneratedStagingName')
  )
  assert.ok(sweep.length > 0, 'the staging sweep must exist')
  assert.doesNotMatch(sweep, /options: \[\.skipsHiddenFiles\]/)
  assert.match(sweep, /options: \[\]/)
  assert.match(PLUGIN_SOURCE, /static func isAppGeneratedStagingName/)
})

test('round-4 T1 closes the Profile-tree gate race after queueing', () => {
  // The entry-point gate (`pluginWritesAllowed`) is evaluated before the task
  // queues on the runtime gate, so the state can move on while it waits: a
  // Runtime update that was already in flight can reach `.confirmed`, and a
  // confirmed transaction still holds the rollback snapshot for the Profile
  // tree the queued operation is about to mutate. The re-check must therefore
  // live inside the gate, before any side effect.
  const execute = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('private func executeDesktopPluginOperation('),
    SETTINGS_SOURCE.indexOf('private func pluginOperationFailureMessage(')
  )
  assert.ok(execute.length > 0, 'executeDesktopPluginOperation must exist')
  const recheck = execute.indexOf('DshRuntimeMutationGate.allowsProfileTreeMutation(DshStateManager.shared.current)')
  assert.ok(recheck > 0, 'the plugin mutation must re-check the Profile-tree gate after queueing')
  assert.ok(
    recheck < execute.indexOf('context.isFresh('),
    'the re-check must come before the stale-context check and every side effect'
  )
  assert.match(execute, /guard DshRuntimeMutationGate\.allowsProfileTreeMutation[\s\S]{0,60}else \{/)
  assert.ok(
    (SETTINGS_SOURCE.match(/withRuntimeOperation \{/g) || []).length >= 5,
    'every plugin mutation runs through the runtime gate'
  )

  // The uninstall entry point used the weaker general-settings gate while every
  // other plugin entry used the Profile-tree gate.
  const remove = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('private func startPluginRemove(name: String) -> Bool {'),
    SETTINGS_SOURCE.indexOf('private func startPluginRemove(name: String) -> Bool {') + 800
  )
  assert.ok(remove.length > 0, 'startPluginRemove must exist')
  assert.match(remove, /guard pluginWritesAllowed, !isOperatingPlugin, !isSwitchingProfile else \{ return false \}/)

  // A Runtime update must not queue behind a plugin transaction: both hold the
  // same gate, and the reordering would be invisible to the user.
  assert.match(
    SETTINGS_SOURCE,
    /guard pluginMutationsAllowed, !isUpdatingRuntime, !isOperatingPlugin else \{ return \}/
  )
  assert.match(
    SETTINGS_SOURCE,
    /public var runtimeUpdateAllowed: Bool \{[\s\S]{0,300}!isOperatingPlugin/
  )

  // The recovery surface must stay reachable. `removePluginFromRecovery`
  // already requires a fully settled idle state, so the stricter in-gate check
  // cannot dead-lock the escape hatch that exists for a broken Runtime.
  const recoveryRemoval = SETTINGS_SOURCE.slice(
    SETTINGS_SOURCE.indexOf('public func removePluginFromRecovery('),
    SETTINGS_SOURCE.indexOf('public func removePluginFromRecovery(') + 1400
  )
  assert.match(recoveryRemoval, /state\.runtimeState\.phase == \.idle/)
  assert.match(recoveryRemoval, /state\.runtimeState\.pending == nil/)
  // ...and the coordinator's adopt path never routes through the plugin
  // mutation helper.
  assert.doesNotMatch(COORDINATOR_SOURCE, /executeDesktopPluginOperation/)
})
