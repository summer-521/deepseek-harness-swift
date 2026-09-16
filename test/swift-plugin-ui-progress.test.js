import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { functionBody } from './source-assertions.mjs'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const viewModelPath = path.join(
  repositoryDirectory, 'Sources', 'SettingsUI', 'SettingsViewModel.swift'
)
const pluginsViewPath = path.join(
  repositoryDirectory, 'Sources', 'SettingsUI', 'PluginsTabView.swift'
)

test('P02 settings exposes durable plugin phases and outcome distinctions', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')

  for (const phase of [
    'case preparing',
    'case changing(action:',
    'case verifying',
    'case restoring',
    'case completed',
    'case recoveryRequired',
  ]) {
    assert.match(viewModel, new RegExp(phase.replace(/[().:?]/g, '\\$&')))
  }
  for (const outcome of [
    'case succeeded',
    'case restored',
    'case recoveryRequired',
    'case externalModification',
  ]) {
    assert.match(viewModel, new RegExp(outcome))
  }

  assert.match(viewModel, /DshPluginOperationCoordinator\.shared\.pendingOperation/)
  assert.match(viewModel, /beginPluginOperationProgress\(action:/)
  assert.match(viewModel, /finishPluginOperationFailed\(actionDescription:/)
  assert.match(viewModel, /Task\.sleep\(nanoseconds: 2_500_000_000\)/)
  assert.match(viewModel, /if operation\.phase == \.committed \{\s*\/\/[\s\S]*?schedulePluginOperationSuccessDismissal\(\)/)
  assert.match(viewModel, /pluginOperationDisplayGeneration == generation/)
  assert.match(viewModel, /pluginOperationOutcome == \.succeeded/)
  assert.match(viewModel, /pluginOperationDismissTask\?\.cancel\(\)/)
  assert.match(viewModel, /finalizeCommittedOperation\(operationID: result\.operationID\)/)
  assert.match(viewModel, /hasPersistedOperationRecord/)
  assert.match(pluginsView, /viewModel\.pluginOperationPhase/)
  assert.match(pluginsView, /ProgressView\(\)/)
  assert.match(pluginsView, /viewModel\.isOperatingPlugin \|\| !viewModel\.pluginMutationsAllowed/)

  // Read-only update inspection remains available while a mutation is active;
  // only the mutation buttons are gated by the operation lock.
  const inspectionButton = pluginsView.slice(
    pluginsView.indexOf('Text(viewModel.isCheckingPluginUpdates ?'),
    pluginsView.indexOf('Text(viewModel.isInspectingPlugins ?')
  )
  assert.doesNotMatch(inspectionButton, /isOperatingPlugin/)
})

test('P02 plugin list keeps four categories and a read-only search/exception filter', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')

  for (const category of ['受管理', '本地', '普通', '异常']) {
    assert.match(viewModel, new RegExp(`case \\w+ = "${category}"`))
  }
  assert.match(viewModel, /pluginSearchText/)
  assert.match(viewModel, /pluginExceptionsOnly/)
  assert.match(viewModel, /filteredInstalledPlugins/)
  assert.match(viewModel, /localizedCaseInsensitiveContains/)
  assert.match(viewModel, /func plugins\(in category: DshPluginListCategory\)/)
  assert.match(viewModel, /case \.missingPackage, \.notComposed, \.patchReferenceMissing/)
  assert.match(pluginsView, /搜索插件名称、版本或描述/)
  assert.match(pluginsView, /仅异常/)
  assert.match(pluginsView, /DshPluginListCategory\.allCases/)
})

test('P02 startup recovery synchronizes and clears stale plugin operation UI state', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const appSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'AppDelegate.swift'),
    'utf8'
  )
  const windowSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'MainWindow', 'MainWindowController.swift'),
    'utf8'
  )

  assert.match(viewModel, /public func synchronizePersistedPluginOperationState\(\)/)
  assert.match(viewModel, /case \.loaded\(let operation\):[\s\S]*?applyPluginOperationState\(operation\)[\s\S]*?schedulePluginOperationSuccessDismissal\(\)/)
  assert.match(viewModel, /case \.corrupt\(let detail\):[\s\S]*?pluginOperationPhase = \.recoveryRequired[\s\S]*?pluginOperationOutcome = \.recoveryRequired/)
  assert.match(viewModel, /case \.absent:[\s\S]*?pluginOperationPhase = nil[\s\S]*?pluginOperationOutcome = nil[\s\S]*?pluginOperationDetail = nil/)
  assert.match(viewModel, /if let operation = coordinator\.pendingOperation[\s\S]*?else if !self\.isOperatingPlugin \{[\s\S]*?synchronizePersistedPluginOperationState\(\)/)
  assert.doesNotMatch(viewModel, /restorePersistedPluginOperationState/)

  const recoveryIndex = appSource.indexOf('recoverPendingPluginOperationDuringStartup')
  const appSyncIndex = appSource.indexOf('synchronizePersistedPluginOperationState')
  assert.ok(recoveryIndex >= 0 && appSyncIndex > recoveryIndex)

  const finalizeIndex = windowSource.indexOf('finalizeCommittedOperation(operationID: operationID)')
  const windowSyncIndex = windowSource.indexOf('synchronizePersistedPluginOperationState', finalizeIndex)
  assert.ok(finalizeIndex >= 0 && windowSyncIndex > finalizeIndex)
  assert.match(viewModel, /Task\.sleep\(nanoseconds: 2_500_000_000\)/)
})

test('P02 retry is fail-closed and never opts out of release-age policy', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')

  assert.match(viewModel, /canRetryPluginOperation/)
  assert.match(viewModel, /pluginOperationOutcome == \.restored/)
  assert.match(viewModel, /case \.absent = DshPluginOperationCoordinator\.shared\.persistedStatus/)
  assert.match(viewModel, /func retryLastPluginOperation\(\)/)
  assert.match(viewModel, /startPluginInstall\(spec: spec, ignoringMinimumReleaseAge: false\)/)
  assert.match(viewModel, /allowingDowngrade: Bool = false/)
  assert.match(viewModel, /pendingPluginDowngrade/)
  assert.match(viewModel, /resolveInstallCandidateVersion\(spec: spec, registry: registry\)/)
  assert.match(viewModel, /isInstallDowngrade\(installed: installed, candidate: candidate\.version\)/)
  assert.match(viewModel, /confirmPendingPluginDowngrade\(\)/)
  assert.match(viewModel, /cancelPendingPluginDowngrade\(\)/)
  assert.match(viewModel, /notePluginOperationProgress\(line\)/)
  assert.match(viewModel, /pluginOperationProgressText/)
  assert.match(viewModel, /startPluginUpdate\(name: name, ignoringMinimumReleaseAge: false\)/)
  assert.match(viewModel, /startPluginUpdateAll\(ignoringMinimumReleaseAge: false\)/)
  assert.match(viewModel, /startPluginRemove\(name: name\)/)
  assert.match(viewModel, /DshPluginManager\.isMinimumReleaseAgeViolation\(error\)/)
  assert.match(viewModel, /preflightPluginUpdate\(/)
  assert.match(viewModel, /preflightAllPluginUpdates\(/)
  assert.match(viewModel, /finishPluginUpdatePreflight\(/)
  assert.match(pluginsView, /安全重试/)
  assert.match(pluginsView, /viewModel\.canRetryPluginOperation/)
})

test('plugin install gates tag downgrades and streams download progress', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')
  const settingsView = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'SettingsUI', 'SettingsView.swift'),
    'utf8'
  )
  const managerSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginManager.swift'),
    'utf8'
  )

  assert.match(viewModel, /finishPluginInstallDowngradeGate\(pending\)/)
  assert.match(settingsView, /降级安装插件？/)
  assert.match(settingsView, /viewModel\.pendingPluginDowngrade != nil/)
  assert.match(settingsView, /confirmPendingPluginDowngrade\(\)/)
  assert.match(settingsView, /pendingPluginDowngradeMessage/)
  assert.match(pluginsView, /viewModel\.pluginOperationProgressText/)
  assert.match(managerSource, /resolveInstallCandidateVersion\(spec: String, registry: String\)/)
  assert.match(managerSource, /dist-tags/)
  assert.match(managerSource, /thinLinkFetchArguments/)
  assert.match(managerSource, /progressHandler/)
  assert.match(managerSource, /onProgressLine/)
})

test('M2 plugin UI gates shared web writes and isolates update targets', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')
  const windowSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'MainWindow', 'MainWindowController.swift'),
    'utf8'
  )

  assert.match(viewModel, /public var pluginWritesAllowed[\s\S]*appProfile == \.desktop/)
  assert.match(viewModel, /当前为 web Profile：与终端 dsh web 共享插件目录，插件安装、更新和卸载已禁用/)
  assert.match(pluginsView, /!viewModel\.pluginWritesAllowed/)
  assert.match(viewModel, /outdatedPluginsContext/)
  assert.match(viewModel, /invalidateOutdatedPlugins/)
  assert.match(viewModel, /requestGeneration == pluginUpdateRequestGeneration/)
  assert.match(viewModel, /state\.appProfile == checked\.0\.profile/)
  assert.match(viewModel, /当前没有可更新的第三方插件。/)

  assert.match(windowSource, /markCommittedPluginCleanupFailure\(/)
  assert.match(windowSource, /let recoveryError = DshPluginOperationError\.recoveryRequired\(/)
  assert.match(windowSource, /startupRecoveryIsPluginOperation = true/)
  assert.match(viewModel, /pending\?\.phase == \.committed[\s\S]*outcome = \.recoveryRequired/)
})

test('P03 plugin updates offer the registry versions instead of a typed spec', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')
  const manager = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginManager.swift'),
    'utf8',
  )

  // The picker reads every published version, because `pnpm outdated` only
  // ever reports `latest` — which is what these plugins do not publish.
  assert.match(manager, /public func publishedPluginVersions\(/)
  assert.match(manager, /document\["dist-tags"\]/)
  assert.match(manager, /DshPackageVersion\.sortedNewestFirst/)
  assert.match(manager, /public func newerThan\(_ installed: String\?\)/)

  assert.match(viewModel, /public struct PluginVersionChoice/)
  assert.match(viewModel, /public func choosePluginVersion\(for plugin: DshPluginItem\)/)
  // Tolerant of arguments added later: the picker reads the packument for that
  // plugin, whatever else it passes along with the name.
  assert.match(viewModel, /DshPluginManager\.shared\.publishedPluginVersions\(\s*for: plugin\.name\b/)
  assert.match(viewModel, /没有更新的版本：当前/)
  assert.match(viewModel, /public func confirmPluginVersionChoice\(\)/)
  assert.match(viewModel, /public func cancelPluginVersionChoice\(\)/)
  // Selecting a version still goes through the normal install pipeline, so the
  // downgrade gate and the release-age preflight keep applying.
  assert.match(viewModel, /startPluginInstall\(spec: spec, ignoringMinimumReleaseAge: false, asUpdate: true\)/)

  // The row opens the picker for every mutable plugin, not only those with a
  // `latest`-based update, and the sheet lists the versions.
  assert.match(pluginsView, /Button\("更新…"\) \{ viewModel\.choosePluginVersion\(for: plugin\) \}/)
  assert.doesNotMatch(pluginsView, /Button\("更新"\) \{ viewModel\.updatePlugin\(name: plugin\.name\) \}/)
  assert.match(pluginsView, /\.sheet\(item: Binding\([\s\S]*viewModel\.pluginVersionChoice/)
  assert.match(pluginsView, /Toggle\("显示更早的版本"/)
  assert.match(pluginsView, /choice\.tagLine\(for: version\)/)
})

test('P03 plugin rows can park a plugin without uninstalling it', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')
  const manager = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginManager.swift'),
    'utf8',
  )
  const state = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginOperationState.swift'),
    'utf8',
  )

  // Activation is a composition edit, not an install: the manifest entry is
  // the only thing removed.
  assert.match(manager, /public func setPluginActivation\(/)
  assert.match(manager, /try updateProfileBundle\(trimmed, removing: !enabled, profileDir: profileDir\)/)
  assert.match(manager, /public let isEnabled: Bool/)
  assert.match(manager, /isEnabled: isManaged \|\| bundles\.map \{ \$0\.contains\(name\) \} \?\? true/)
  assert.match(manager, /内置桥接插件由 DSH Desktop 维护，不能启用或禁用/)

  // Both directions are durable actions, so a recovered record says which one
  // was requested instead of flipping whatever it finds.
  assert.match(state, /case enable/)
  assert.match(state, /case disable/)
  assert.match(state, /case \.update, \.remove, \.enable, \.disable:/)

  assert.match(viewModel, /public func togglePluginActivation\(name: String, enabled: Bool\)/)
  assert.match(viewModel, /action: enabled \? \.enable : \.disable/)
  assert.match(viewModel, /正在\\\(verb\)插件 \\\(name\)…/)

  // The row keeps the order 更新… / 启用-禁用 / 卸载 and marks the parked state.
  const updateIndex = pluginsView.indexOf('viewModel.choosePluginVersion(for: plugin)')
  const toggleIndex = pluginsView.indexOf('viewModel.togglePluginActivation(')
  const removeIndex = pluginsView.indexOf('viewModel.requestPluginRemoval(name: plugin.name)')
  assert.ok(updateIndex > 0 && toggleIndex > updateIndex && removeIndex > toggleIndex,
    'enable/disable must sit between update and uninstall')
  assert.match(pluginsView, /Button\(plugin\.isEnabled \? "禁用" : "启用"\)/)
  assert.match(pluginsView, /Text\("已禁用"\)/)
})

test('P03 uninstalling asks first and says what is removed and what is kept', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')
  const manager = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Plugins', 'DshPluginManager.swift'),
    'utf8'
  )

  // The row button opens a confirmation instead of deleting a plugin's setup in
  // one click.
  assert.match(pluginsView, /Button\("卸载"\) \{ viewModel\.requestPluginRemoval\(name: plugin\.name\) \}/)
  assert.doesNotMatch(pluginsView, /viewModel\.removePlugin\(name: plugin\.name\)/)
  assert.match(pluginsView, /\.alert\(\s*"卸载插件",/)
  assert.match(pluginsView, /Button\("取消", role: \.cancel\)/)
  assert.match(pluginsView, /Button\("卸载", role: \.destructive\)/)
  assert.match(pluginsView, /Text\(pending\.confirmationMessage\)/)

  // The uninstall itself happens only in the confirmed branch. The request
  // lives exactly as long as the confirmation — the alert clears it on
  // dismissal and this clears it here — so a start the gate refuses reports its
  // reason rather than leaving a request that nothing would present again.
  const confirm = functionBody(viewModel, 'public func confirmPluginRemoval()')
  assert.match(confirm, /pendingPluginRemoval = nil\s*\n\s*guard startPluginRemove\(name: pending\.name\) else/)
  assert.match(confirm, /alertMessage = pluginMutationUnavailableReason/)
  assert.doesNotMatch(confirm, /removePlugin\(name: pending\.name\)/)
  assert.match(functionBody(viewModel, 'public func cancelPluginRemoval()'), /pendingPluginRemoval = nil/)
  // The alert's dismissal is the other owner of the request; between them the
  // request can never outlive the dialog it belongs to.
  assert.match(pluginsView, /if !presented \{ viewModel\.cancelPluginRemoval\(\) \}/)
  // The request is gated exactly like the button it replaces.
  assert.match(
    functionBody(viewModel, 'public func requestPluginRemoval(name: String)'),
    /guard !isOperatingPlugin, pluginMutationsAllowed, pluginWritesAllowed else \{ return \}/
  )

  // The confirmation belongs to the page, not to every row: one alert per row
  // gives every visible row a candidate for presenting the same dialog.
  const row = functionBody(pluginsView, 'private func pluginRow(for plugin: DshPluginItem)')
  assert.doesNotMatch(row, /\.alert\(/)
  const body = pluginsView.slice(pluginsView.indexOf('public var body: some View'), pluginsView.indexOf('@ViewBuilder'))
  assert.match(body, /\.sheet\(item: Binding\(/)
  assert.match(body, /\.alert\(\s*"卸载插件",/, 'the alert is attached where the sheet is: the page root')
  assert.match(pluginsView, /Text\(pending\.confirmationMessage\)/)

  // A version list still in flight must not reopen the picker for a plugin the
  // user just removed: confirming it would reinstall what was just deleted.
  const choose = functionBody(viewModel, 'public func choosePluginVersion(for plugin: DshPluginItem)')
  assert.match(choose, /pluginVersionRequestGeneration \+= 1/)
  assert.match(choose, /let generation = pluginVersionRequestGeneration/)
  assert.match(choose, /guard self\.pluginVersionRequestGeneration == generation/)
  assert.match(
    choose,
    /self\.installedPlugins\.contains\(where: \{ \$0\.name == plugin\.name \}\)/,
    'the answer is dropped when the plugin is no longer installed',
  )
  assert.doesNotMatch(
    choose,
    /filteredInstalledPlugins/,
    'the search term or the exception filter must not decide whether a paid-for answer is valid',
  )
  assert.match(
    choose,
    /guard self\.pluginVersionRequestGeneration == generation else \{ return \}\s*\n\s*self\.alertMessage/,
    'a stale failure must not overwrite what the user is looking at now',
  )
  const remove = functionBody(viewModel, 'private func startPluginRemove(name: String) -> Bool')
  assert.match(remove, /pluginVersionRequestGeneration \+= 1/, 'starting a removal invalidates a pending list')

  // The message states what is deleted, what survives, and what reinstalling
  // costs, naming the plugin, its version and the Profile.
  const message = functionBody(manager, 'public var confirmationMessage: String')
  assert.match(message, /卸载 \\\(name\)/)
  assert.match(message, /\\\(installedVersion\)/)
  assert.match(message, /当前 \\\(profile\) Profile 删除这个插件/)
  assert.match(message, /已安装的包、版本/)
  assert.match(message, /激活列表/)
  assert.match(message, /其他插件、Runtime 与 Profile 设置都会保留/)
  assert.match(message, /重新安装需要重新配置/)
})

test('P03 the plugin page recovers in place and the picker names its mirror', () => {
  const viewModel = fs.readFileSync(viewModelPath, 'utf8')
  const pluginsView = fs.readFileSync(pluginsViewPath, 'utf8')

  // The recovery panel is not driven by the raw "writes are unavailable" reason:
  // that reason is non-nil during any ordinary operation (the controls really
  // are disabled), and leading the page with it while "正在卸载插件…" is on
  // screen reads as a contradiction.
  assert.match(
    pluginsView,
    /if let reason = viewModel\.pluginWriteRecoveryReason \{\s*\n\s*pluginUnavailablePanel\(reason\)/
  )
  assert.doesNotMatch(
    pluginsView,
    /if let reason = viewModel\.pluginMutationUnavailableReason \{\s*\n\s*pluginUnavailablePanel\(reason\)/
  )
  // The footer keeps the raw reason: it explains the disabled controls.
  assert.match(pluginsView, /viewModel\.pluginMutationUnavailableReason \?\? "安装指定的 npm 插件"/)
  const recoveryReason = functionBody(viewModel, 'public var pluginWriteRecoveryReason: String?')
  assert.match(
    recoveryReason,
    /guard let reason = pluginMutationUnavailableReason, !isOperatingPlugin else \{ return nil \}/
  )
  assert.match(recoveryReason, /case \.preparing, \.changing, \.verifying, \.restoring, \.completed:\s*\n\s*return nil/)
  assert.match(recoveryReason, /case \.recoveryRequired:\s*\n\s*return reason/)
  assert.match(recoveryReason, /case nil:\s*\n\s*return reason/)
  const panel = functionBody(pluginsView, 'private func pluginUnavailablePanel(_ reason: String)')
  assert.match(panel, /Text\(reason\)/)
  assert.match(panel, /Button\("重新检查插件"\)/)
  assert.match(panel, /await viewModel\.inspectPlugins\(\)/)
  assert.match(panel, /Button\("重启 DSH 服务"\)/)
  assert.match(panel, /MainWindowController\.shared\.startAndLoadDsh\(\)/)

  // The version picker says which mirror its list came from, and offers to read
  // it again when the settings moved to another one while it was open.
  assert.match(viewModel, /public let registry: String/)
  assert.match(
    viewModel,
    /publishedPluginVersions\(\s*\n\s*for: plugin\.name,\s*\n\s*registry: registry\s*\n\s*\)/
  )
  assert.match(viewModel, /public var pluginVersionChoiceUsesDifferentRegistry: Bool/)
  assert.match(viewModel, /public func refreshPluginVersionChoice\(\)/)
  const picker = functionBody(pluginsView, 'private func pluginVersionPicker(_ choice: PluginVersionChoice)')
  assert.match(picker, /Text\("来源：\\\(choice\.registry\)"\)/)
  assert.match(picker, /viewModel\.pluginVersionChoiceUsesDifferentRegistry/)
  assert.match(picker, /viewModel\.refreshPluginVersionChoice\(\)/)

  // A local plugin explains why it has no enable/disable rather than leaving a
  // row that silently lacks the buttons.
  assert.match(pluginsView, /本地插件：组合方式由本机路径（file: \/ link:）决定，不提供启用\/禁用。/)
})
