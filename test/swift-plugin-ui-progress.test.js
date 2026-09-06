import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

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
