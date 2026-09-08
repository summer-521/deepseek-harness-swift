#!/usr/bin/env node

// A deliberately tiny pnpm stand-in for the isolated P01 product-chain
// tests. It mutates only the profile in process.cwd(), records the exact
// command line, and never reads or writes a real pnpm store/configuration.
import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
const cwd = process.cwd()
const logFile = process.env.DSH_FAKE_PNPM_LOG
const mode = process.env.DSH_FAKE_PNPM_MODE || ''

function log(line) {
  if (!logFile) return
  fs.appendFileSync(logFile, `${line}\n`)
}

function readManifest() {
  return JSON.parse(fs.readFileSync(path.join(cwd, 'package.json'), 'utf8'))
}

function writeManifest(manifest) {
  fs.writeFileSync(path.join(cwd, 'package.json'), `${JSON.stringify(manifest, null, 2)}\n`)
}

function packageDirectory(name) {
  const parts = name.startsWith('@') ? name.split('/') : [name]
  return path.join(cwd, 'node_modules', ...parts)
}

function writeInstalled(name, version, description = `fixture ${name}`) {
  const target = packageDirectory(name)
  fs.mkdirSync(target, { recursive: true })
  fs.writeFileSync(path.join(target, 'package.json'), `${JSON.stringify({ name, version, description }, null, 2)}\n`)
}

function removeInstalled(name) {
  fs.rmSync(packageDirectory(name), { recursive: true, force: true })
}

function packageNameFromSpec(spec) {
  if (spec.startsWith('file:')) {
    const source = spec.slice('file:'.length)
    const sourceManifest = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8'))
    return { name: sourceManifest.name, version: sourceManifest.version, description: sourceManifest.description }
  }
  const name = spec.startsWith('@')
    ? spec.slice(0, spec.indexOf('@', 1 + spec.indexOf('/')))
    : spec.split('@')[0]
  const version = spec.includes('@') ? spec.slice(spec.lastIndexOf('@') + 1) : '1.0.0'
  return { name, version, description: `fixture ${name}` }
}

function dependencyNames(manifest) {
  return Object.keys(manifest.dependencies || {})
    .filter(name => !name.startsWith('@deepseek-ai/'))
    .filter(name => name !== 'dsh-desktop-host')
}

log(JSON.stringify({ args, cwd, mode, userConfig: process.env.npm_config_userconfig || null }))

const command = args[0]
if (command === 'add') {
  if (mode === 'minimum-release-age' && !args.includes('--config.minimum-release-age=0')) {
    process.stderr.write('MINIMUM_RELEASE_AGE_VIOLATION: fixture package is too new\n')
    process.exit(42)
  }
  const installed = packageNameFromSpec(args[1])
  const manifest = readManifest()
  manifest.dependencies = { ...(manifest.dependencies || {}), [installed.name]: args[1] }
  writeManifest(manifest)
  // The product harness models pnpm's lockfile-only resolver for installs:
  // the copied manifest records the resolution while nothing is linked.
  if (args.includes('--lockfile-only')) {
    process.stdout.write(`preflight resolved ${installed.name}@${installed.version}\n`)
    process.exit(0)
  }
  writeInstalled(installed.name, installed.version, installed.description)
  process.stdout.write(`added ${installed.name}@${installed.version}\n`)
  process.exit(0)
}

if (command === 'update') {
  if (mode === 'partial-minimum-release-age' && args.includes('--lockfile-only')) {
    const manifest = readManifest()
    const names = args.slice(1).filter(arg => !arg.startsWith('-') && arg !== '--latest' && arg !== '--registry')
    const requested = names.length ? names : dependencyNames(manifest)
    // Model pnpm resolving one requested package while silently withholding
    // another candidate that is still inside minimum-release-age. The command
    // succeeds and produces a resolver diff, but deliberately emits no policy
    // keyword: the manager must inspect the requested set instead of treating
    // any diff as proof that the whole batch cleared.
    if (requested.includes('plugin-a') && 'plugin-a' in (manifest.dependencies || {})) {
      manifest.dependencies['plugin-a'] = '2.0.0'
    }
    writeManifest(manifest)
    fs.writeFileSync(path.join(cwd, 'pnpm-lock.yaml'), 'lockfileVersion: 9\nimporters:\n  .:\n    dependencies:\n      plugin-a:\n        specifier: 2.0.0\n')
    process.stdout.write('preflight resolved plugin-a; plugin-b unavailable\n')
    process.exit(0)
  }
  if (mode === 'minimum-release-age' && !args.includes('--config.minimum-release-age=0')) {
    process.stderr.write('MINIMUM_RELEASE_AGE_VIOLATION: fixture package is too new\n')
    process.exit(42)
  }
  if (mode === 'silent-minimum-release-age' && !args.includes('--config.minimum-release-age=0')) {
    process.stdout.write('already up to date within minimum release age policy\n')
    process.exit(0)
  }
  if (mode === 'silent-no-keyword' && !args.includes('--config.minimum-release-age=0')) {
    process.stdout.write('already up to date\n')
    process.exit(0)
  }
  const manifest = readManifest()
  const names = args.slice(1).filter(arg => !arg.startsWith('-') && arg !== '--latest' && arg !== '--registry')
  const requested = names.length ? names : dependencyNames(manifest)
  // The product harness models pnpm's lockfile-only resolver: it exercises
  // argument parsing and release-age policy while touching only the copied
  // manifest. A real update follows without this flag.
  if (args.includes('--lockfile-only')) {
    for (const name of requested) {
      if (name in (manifest.dependencies || {})) manifest.dependencies[name] = '2.0.0'
    }
    writeManifest(manifest)
    process.stdout.write(`preflight resolved ${requested.join(',')}\n`)
    process.exit(0)
  }
  for (const name of requested) {
    if (!(name in (manifest.dependencies || {}))) continue
    manifest.dependencies[name] = '2.0.0'
    writeInstalled(name, '2.0.0')
  }
  writeManifest(manifest)
  if (mode === 'fail-update-all') {
    process.stderr.write('fixture batch update failed after partial mutation\n')
    process.exit(37)
  }
  process.stdout.write(`updated ${requested.join(',')}\n`)
  process.exit(0)
}

if (command === 'outdated') {
  const manifest = readManifest()
  const outdated = {}
  for (const name of dependencyNames(manifest)) {
    const installedManifest = path.join(packageDirectory(name), 'package.json')
    // A lockfile-only preflight intentionally has no node_modules. Model
    // pnpm outdated reading its resolved direct dependency from the copied
    // manifest in that case, while formal transactions still use the linked
    // package manifest as their source of the current version.
    const current = fs.existsSync(installedManifest)
      ? JSON.parse(fs.readFileSync(installedManifest, 'utf8')).version
      : manifest.dependencies[name]
    if (current !== '2.0.0') {
      outdated[name] = { current, latest: '2.0.0' }
    }
  }
  process.stdout.write(`${JSON.stringify(outdated)}\n`)
  process.exit(Object.keys(outdated).length ? 1 : 0)
}

if (command === 'remove') {
  const name = args[1]
  const manifest = readManifest()
  if (manifest.dependencies) delete manifest.dependencies[name]
  writeManifest(manifest)
  removeInstalled(name)
  process.stdout.write(`removed ${name}\n`)
  process.exit(0)
}

process.stderr.write(`unsupported fake pnpm command: ${args.join(' ')}\n`)
process.exit(64)
