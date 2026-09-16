#!/usr/bin/env node
// Release metadata for the Swift shell in one place.
//
// A release rewrites four hand-edited spots — `Version.xcconfig`, the three
// README references, and the newest appcast item — and they disagree easily:
// the feed can advertise the previous build while the README downloads the
// previous DMG. Both rewrites live here as pure functions with a `--check`
// mode, the `release-prepare.sh` orchestration calls them with `--write`, and
// `test/swift-release-consistency.test.js` guards the committed result.
//
// Usage:
//   node scripts/release-metadata.mjs bump --version 1.2.6 --build 17 --write
//   node scripts/release-metadata.mjs appcast --version 1.2.6 --build 17 \
//     --length 50425442 --signature <ed signature> --notes-file <markdown> \
//     [--url <dmg url>] [--write]
//
// Without a mode flag both subcommands only report what they would change and
// exit non-zero, so a mistyped invocation cannot rewrite a release file.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repositoryDirectory = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

export const defaultPaths = {
  xcconfig: path.join(repositoryDirectory, 'Version.xcconfig'),
  readme: path.join(repositoryDirectory, 'README.md'),
  appcast: path.join(repositoryDirectory, 'appcast-swift.xml'),
}

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const pad = (value) => String(value).padStart(2, '0')

/** RFC 822 timestamp in the release machine's own zone, as Sparkle expects. */
export function rfc822(date) {
  const offsetMinutes = -date.getTimezoneOffset()
  const sign = offsetMinutes >= 0 ? '+' : '-'
  const absolute = Math.abs(offsetMinutes)
  return `${DAYS[date.getDay()]}, ${pad(date.getDate())} ${MONTHS[date.getMonth()]} ${date.getFullYear()} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())} ` +
    `${sign}${pad(Math.floor(absolute / 60))}${pad(absolute % 60)}`
}

export function readXcconfig(source) {
  const version = source.match(/^\s*SWIFT_APP_VERSION\s*=\s*(\S+)\s*$/m)?.[1]
  const build = source.match(/^\s*SWIFT_APP_BUILD\s*=\s*(\S+)\s*$/m)?.[1]
  if (!version || !build) throw new Error('Version.xcconfig must define SWIFT_APP_VERSION and SWIFT_APP_BUILD')
  return { version, build }
}

function replaceExactlyOnce(source, pattern, replacement, label) {
  const matches = source.match(new RegExp(pattern.source, `${pattern.flags.replace('g', '')}g`))
  const count = matches?.length ?? 0
  if (count !== 1) throw new Error(`${label}: expected exactly one match, found ${count}`)
  return source.replace(pattern, replacement)
}

/** The version config the bundle reads; MARKETING_VERSION/CURRENT_PROJECT_VERSION derive from it. */
export function bumpXcconfig(source, { version, build }) {
  let next = replaceExactlyOnce(
    source,
    /^(\s*SWIFT_APP_VERSION\s*=\s*)\S+\s*$/m,
    `$1${version}`,
    'SWIFT_APP_VERSION',
  )
  next = replaceExactlyOnce(
    next,
    /^(\s*SWIFT_APP_BUILD\s*=\s*)\S+\s*$/m,
    `$1${build}`,
    'SWIFT_APP_BUILD',
  )
  return next
}

/** The version the README currently advertises, which is what a bump moves away from. */
export function readmeVersion(source) {
  const version = source.match(/releases\/download\/v(\d+\.\d+\.\d+)\/DSH-Desktop-\d+\.\d+\.\d+-arm64\.dmg/)?.[1]
  if (!version) throw new Error('README has no DMG download link to read the current version from')
  return version
}

/**
 * The three README references the release checklist edits by hand: the version
 * badge (URL and its visible text), the release-tag links, and the DMG download
 * link whose file name also carries the version.
 */
export function bumpReadme(source, { previousVersion, version }) {
  const expected = {
    tag: (source.match(new RegExp(`releases/tag/v${previousVersion.replaceAll('.', '\\.')}\\b`, 'g')) ?? []).length,
    badge: (source.match(new RegExp(`badge/Swift%20Native-v${previousVersion.replaceAll('.', '\\.')}-`, 'g')) ?? []).length,
    badgeText: (source.match(new RegExp(`Swift 原生版 v${previousVersion.replaceAll('.', '\\.')}`, 'g')) ?? []).length,
    download: (source.match(new RegExp(`releases/download/v${previousVersion.replaceAll('.', '\\.')}`, 'g')) ?? []).length,
  }
  for (const [label, count] of Object.entries(expected)) {
    if (count === 0) {
      throw new Error(`README has no ${label} reference to v${previousVersion}`)
    }
  }

  let next = source
    .replaceAll(`releases/tag/v${previousVersion}`, `releases/tag/v${version}`)
    .replaceAll(`badge/Swift%20Native-v${previousVersion}-`, `badge/Swift%20Native-v${version}-`)
    .replaceAll(`Swift 原生版 v${previousVersion}`, `Swift 原生版 v${version}`)
    .replaceAll(`releases/download/v${previousVersion}`, `releases/download/v${version}`)
    .replaceAll(`DSH-Desktop-${previousVersion}-arm64.dmg`, `DSH-Desktop-${version}-arm64.dmg`)

  return { source: next, replacements: expected }
}

function requireMatch(value, pattern, label) {
  if (typeof value !== 'string' || !pattern.test(value)) {
    throw new Error(`${label} is missing or malformed: ${JSON.stringify(value)}`)
  }
  return value
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * One Sparkle item, in the shape the published feed already uses. Everything
 * Sparkle needs to accept the update is required: the archive length and EdDSA
 * signature must describe the exact bytes that get uploaded.
 */
export function buildAppcastItem({
  version,
  build,
  url,
  length,
  signature,
  notes,
  publishedAt = new Date(),
  minimumSystemVersion,
  hardwareRequirements = 'arm64',
}) {
  requireMatch(version, /^\d+\.\d+\.\d+$/, 'version')
  requireMatch(String(build), /^\d+$/, 'build')
  requireMatch(url, /^https:\/\/\S+$/, 'enclosure url')
  requireMatch(String(length), /^[1-9]\d*$/, 'archive length')
  requireMatch(signature, /^[A-Za-z0-9+/]{40,}={0,2}$/, 'EdDSA signature')
  requireMatch(minimumSystemVersion, /^\d+(\.\d+)?$/, 'minimum system version')
  requireMatch(hardwareRequirements, /^[a-z0-9]+$/, 'hardware requirements')
  if (typeof notes !== 'string' || notes.trim().length === 0) {
    throw new Error('release notes are empty')
  }
  if (notes.includes(']]>')) {
    throw new Error('release notes contain the CDATA terminator ]]>')
  }
  if (!url.includes(`/v${version}/`) || !url.includes(`DSH-Desktop-${version}-arm64.dmg`)) {
    throw new Error(`enclosure url does not address the ${version} arm64 DMG: ${url}`)
  }

  const tag = `https://github.com/summer-521/deepseek-harness-swift/releases/tag/v${version}`
  return `        <item>
            <title>${version}</title>
            <pubDate>${rfc822(publishedAt)}</pubDate>
            <link>${tag}</link>
            <sparkle:version>${build}</sparkle:version>
            <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${minimumSystemVersion}</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>${hardwareRequirements}</sparkle:hardwareRequirements>
            <description sparkle:format="markdown"><![CDATA[
${notes.trimEnd()}
]]></description>
            <enclosure url="${url}" length="${length}" type="application/octet-stream" sparkle:edSignature="${signature}"/>
        </item>`
}

/** Sparkle reads the first item first, so the newest release is inserted there. */
export function insertAppcastItem(appcast, item, { version, build }) {
  if (!appcast.includes('<channel>')) throw new Error('appcast has no <channel>')
  const duplicateTag = appcast.includes(`releases/tag/v${version}<`)
  const duplicateBuild = appcast.includes(`<sparkle:version>${build}</sparkle:version>`)
  if (duplicateTag || duplicateBuild) {
    throw new Error(`appcast already publishes ${version} (build ${build})`)
  }
  const firstItem = appcast.indexOf('<item>')
  if (firstItem < 0) throw new Error('appcast has no <item> to insert before')
  const lineStart = appcast.lastIndexOf('\n', firstItem) + 1
  return `${appcast.slice(0, lineStart)}${item}\n${appcast.slice(lineStart)}`
}

/** The newest item, which is what a release must have just written. */
export function newestItem(appcast) {
  const start = appcast.indexOf('<item>')
  const end = appcast.indexOf('</item>', start)
  if (start < 0 || end < 0) throw new Error('appcast has no item')
  return appcast.slice(start, end)
}

function parseArguments(argv) {
  const [command, ...rest] = argv
  const options = {}
  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index]
    if (!token.startsWith('--')) throw new Error(`unexpected argument: ${token}`)
    const name = token.slice(2)
    if (name === 'check' || name === 'write') {
      options.mode = name
      continue
    }
    const value = rest[index + 1]
    if (value === undefined || value.startsWith('--')) throw new Error(`--${name} needs a value`)
    options[name] = value
    index += 1
  }
  if (options.mode === undefined) options.mode = 'check'
  return { command, options }
}

function report(mode, file, changed, detail) {
  const label = path.relative(repositoryDirectory, file)
  if (mode === 'write') {
    fs.writeFileSync(file, changed)
    console.log(`updated ${label} (${detail})`)
    return 0
  }
  console.log(`would update ${label} (${detail})`)
  return 1
}

function runBump({ options, paths }) {
  const xcconfig = fs.readFileSync(paths.xcconfig, 'utf8')
  const readme = fs.readFileSync(paths.readme, 'utf8')
  const configured = readXcconfig(xcconfig)
  // The README is the authority for its own previous version: a re-run after a
  // partial failure must not look for a version the README never carried.
  const advertised = readmeVersion(readme)
  const { version, build } = options
  requireMatch(version, /^\d+\.\d+\.\d+$/, 'version')
  requireMatch(build, /^\d+$/, 'build')

  const nextXcconfig = bumpXcconfig(xcconfig, { version, build })
  const { source: nextReadme, replacements } = bumpReadme(readme, {
    previousVersion: advertised,
    version,
  })
  if (nextXcconfig === xcconfig && nextReadme === readme) {
    console.log(`already at ${version} (build ${build})`)
    return 0
  }

  const detail = `${configured.version} (build ${configured.build}) → ${version} (build ${build}); ` +
    `README tag=${replacements.tag} badge=${replacements.badge} download=${replacements.download}`
  let status = 0
  if (nextXcconfig !== xcconfig) {
    status = Math.max(status, report(options.mode, paths.xcconfig, nextXcconfig, detail))
  }
  if (nextReadme !== readme) {
    status = Math.max(status, report(options.mode, paths.readme, nextReadme, detail))
  }
  return status
}

function runAppcast({ options, paths }) {
  const appcast = fs.readFileSync(paths.appcast, 'utf8')
  const version = requireMatch(options.version, /^\d+\.\d+\.\d+$/, 'version')
  const build = requireMatch(options.build, /^\d+$/, 'build')
  const length = requireMatch(options.length, /^[1-9]\d*$/, 'archive length')
  const signature = requireMatch(options.signature, /^[A-Za-z0-9+/]{40,}={0,2}$/, 'EdDSA signature')
  const notes = fs.readFileSync(
    requireMatch(options['notes-file'], /^\S+$/, 'release notes file'),
    'utf8',
  )
  const minimumSystemVersion = options['minimum-system-version'] ?? '26.0'
  const url = options.url
    ?? `https://github.com/summer-521/deepseek-harness-swift/releases/download/v${version}/DSH-Desktop-${version}-arm64.dmg`

  const item = buildAppcastItem({
    version,
    build,
    url,
    length,
    signature,
    notes,
    minimumSystemVersion,
    publishedAt: options['published-at'] ? new Date(options['published-at']) : new Date(),
  })
  const next = insertAppcastItem(appcast, item, { version, build })
  return report(options.mode, paths.appcast, next, `${version} build ${build}, length ${length}`)
}

function main() {
  const { command, options } = parseArguments(process.argv.slice(2))
  const paths = defaultPaths
  switch (command) {
    case 'bump':
      return runBump({ options, paths })
    case 'appcast':
      return runAppcast({ options, paths })
    case 'show':
      console.log(JSON.stringify({ ...readXcconfig(fs.readFileSync(paths.xcconfig, 'utf8')), newest: newestItem(fs.readFileSync(paths.appcast, 'utf8')).trim() }, null, 2))
      return 0
    default:
      throw new Error(`unknown command: ${command ?? '(none)'} (bump | appcast | show)`)
  }
}

/**
 * True when this file is the process entry point. Both sides are realpath'd:
 * a caller may name the script through a symlinked directory (`/var` is
 * `/private/var` on macOS, `/tmp` is `/private/tmp`), and a textual comparison
 * would then skip `main()` and exit 0 having done nothing — the worst possible
 * failure mode for a release tool.
 */
function isEntryPoint() {
  if (!process.argv[1]) return false
  try {
    return fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return false
  }
}

if (isEntryPoint()) {
  try {
    process.exit(main())
  } catch (error) {
    console.error(`release-metadata: ${error.message}`)
    process.exit(2)
  }
}
