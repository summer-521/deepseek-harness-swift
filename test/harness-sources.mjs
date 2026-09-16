// Shared Swift source sets for the integration harnesses.
//
// There is no Xcode test target: each `test/swift-*.integration.test.js`
// compiles the app sources it exercises with `xcrun swiftc`, so every new
// `Sources/**/*.swift` file has to join every harness that references it. That
// chore is easy to miss — landing `DshFamilyClosure.swift` and then
// `NodeChildEnvironment.swift` each meant editing eight test files, and a miss
// shows up as an unexplained harness compile failure.
//
// The sets below are exactly the file lists those tests used to spell out one
// by one; adding a source to the runtime or plugin stack is now a single edit
// here. A harness that needs something outside its set still adds it locally.

import path from 'node:path'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const source = (...components) => path.join(testDirectory, '..', 'Sources', ...components)

/** State, the managed Node runtime and its environment, semver and launch context. */
export const runtimeSources = [
  source('State', 'DshState.swift'),
  source('Service', 'NodeChildEnvironment.swift'),
  source('Service', 'NodeRuntime.swift'),
  source('Service', 'DshLaunchContext.swift'),
  source('Versions', 'DshSemanticVersion.swift'),
]

/** `runtimeSources` plus the managed runtime version stack. */
export const versionSources = [
  ...runtimeSources,
  source('Versions', 'DshVersionManager.swift'),
  source('Versions', 'DshFamilyClosure.swift'),
  source('Versions', 'DshProfileLinkRepair.swift'),
]

/** `versionSources` plus the plugin manager and its secret redactor. */
export const pluginSources = [
  ...versionSources,
  source('Service', 'DshSecretRedactor.swift'),
  source('Plugins', 'DshPluginManager.swift'),
]

/** `pluginSources` plus the plugin operation state machine. */
export const pluginOperationSources = [
  ...pluginSources,
  source('Plugins', 'DshPluginOperationState.swift'),
]

/** `pluginOperationSources` plus the operation coordinator: the full plugin stack. */
export const pluginProductChainSources = [
  ...pluginOperationSources,
  source('Plugins', 'DshPluginOperationCoordinator.swift'),
]

/** Every set the manifest exports, for the guard test that keeps them honest. */
export const groups = {
  runtimeSources,
  versionSources,
  pluginSources,
  pluginOperationSources,
  pluginProductChainSources,
}
