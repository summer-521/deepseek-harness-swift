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
//   node scripts/release-metadata.mjs published --version 1.2.6 --build 17 \
//     [--appcast <feed file>]
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

/** Numeric comparison of `x.y.z` versions; these releases never carry a suffix. */
export function compareVersions(left, right) {
  const leftParts = left.split('.').map(Number)
  const rightParts = right.split('.').map(Number)
  for (let index = 0; index < 3; index += 1) {
    if (leftParts[index] !== rightParts[index]) {
      return leftParts[index] < rightParts[index] ? -1 : 1
    }
  }
  return 0
}

/** The highest build number the feed already publishes. */
export function highestPublishedBuild(appcast) {
  // Read from each item's own `<sparkle:version>`, not from the file text: a
  // release note that quotes one must not raise the bar for the next release.
  const builds = appcastItems(appcast)
    .map((fields) => Number(fields.build))
    .filter((build) => Number.isInteger(build) && build > 0)
  return builds.length > 0 ? Math.max(...builds) : 0
}

/**
 * Refuse a release that cannot reach the users it is meant for.
 *
 * Sparkle compares the build number, so a build that does not advance is
 * invisible to everyone already on it however correct the version string looks,
 * and a version that moves backwards is a mistake by definition. Re-running the
 * exact release already in `Version.xcconfig` stays allowed: that is how a
 * half-finished release is resumed, and the appcast insert refuses a duplicate
 * item on its own.
 */
export function releaseRegression({ version, build, currentVersion, currentBuild, publishedBuild }) {
  const targetVersion = String(version)
  const targetBuild = Number(build)
  if (compareVersions(targetVersion, currentVersion) < 0) {
    return `version ${targetVersion} is older than the current ${currentVersion}`
  }
  if (publishedBuild > targetBuild) {
    return `build ${targetBuild} is not newer than the newest published build ${publishedBuild}`
  }
  const resuming = compareVersions(targetVersion, currentVersion) === 0 && targetBuild === currentBuild
  if (!resuming && targetBuild <= currentBuild) {
    return `build ${targetBuild} is not newer than the current build ${currentBuild}`
  }
  return null
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
  const clash = appcastItems(appcast).find(
    (fields) => fields.version === version || fields.build === String(build),
  )
  if (clash) {
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

/**
 * What one item says, read from its elements rather than from its text.
 *
 * Release notes are markdown inside a CDATA block, so they can contain any
 * literal a field is recognized by — a pasted `<sparkle:version>17</sparkle:version>`,
 * an example URL, a `length="…"`. Searching the raw item would let those decide
 * whether a release is already public, or which artifact the feed points at, so
 * the notes are removed first and every field is read from the element that
 * carries it.
 */
function itemFields(item) {
  const elements = item.replace(/<description[\s\S]*?<\/description>/g, '')
  const enclosure = elements.match(/<enclosure\b[^>]*>/)?.[0] ?? ''
  const link = elements.match(/<link>([^<]*)<\/link>/)?.[1] ?? ''
  const url = enclosure.match(/\burl="([^"]*)"/)?.[1] ?? ''
  return {
    item,
    version: elements.match(/<title>([^<]*)<\/title>/)?.[1] ?? link.match(/\/v(\d+\.\d+\.\d+)$/)?.[1] ?? '',
    build: elements.match(/<sparkle:version>(\d+)<\/sparkle:version>/)?.[1] ?? '',
    length: Number(enclosure.match(/\blength="(\d+)"/)?.[1] ?? 0),
    url,
    signature: enclosure.match(/sparkle:edSignature="([^"]*)"/)?.[1] ?? '',
  }
}

/** Every item in the feed, as the fields it actually declares. */
export function appcastItems(appcast) {
  return [...appcast.matchAll(/<item>[\s\S]*?<\/item>/g)].map((match) => itemFields(match[0]))
}

/**
 * The item the feed publishes for one version and build, or null.
 *
 * This is the record of what is public: an item in the served appcast names the
 * archive length and EdDSA signature every installed copy verifies its download
 * against, so those bytes may never be replaced afterwards. The build is the
 * identity Sparkle itself compares; the version has to agree as well, because a
 * neighbouring release that reused a number is not this release.
 */
export function publishedItem(appcast, { version, build }) {
  const found = appcastItems(appcast).find(
    (fields) => fields.version === version && fields.build === String(build),
  )
  return found ?? null
}

/**
 * Put one item in the feed: newest first, and an item for the same version and
 * build replaced instead of duplicated.
 *
 * Replacing is what makes a release resumable. A rerun rebuilds the DMG, and a
 * rebuilt DMG has different bytes and a different signature, so the item an
 * earlier attempt wrote describes an artifact that no longer exists; refusing
 * the duplicate would strand that release. Replacing it is safe exactly as long
 * as the public feed does not already carry this version and build — which
 * `release-prepare.sh` proves against `origin/main` before it builds anything.
 *
 * An item that publishes the same thing is left alone. The comparison ignores
 * the publication timestamp, which says when the item was written rather than
 * what it publishes: two runs of the same release produce it seconds apart, and
 * rewriting the feed for that would churn it on every retry.
 */
export function upsertAppcastItem(appcast, item, { version, build }) {
  const existing = publishedItem(appcast, { version, build })
  if (existing === null) return insertAppcastItem(appcast, item, { version, build })
  if (withoutPublishedAt(existing.item) === withoutPublishedAt(item)) return appcast
  return appcast.replace(existing.item, item)
}

/** The item with its `<pubDate>` blanked, so only its content is compared. */
function withoutPublishedAt(item) {
  return item.replace(/<pubDate>[\s\S]*?<\/pubDate>/, '<pubDate/>').trim()
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
  const appcast = fs.readFileSync(paths.appcast, 'utf8')
  const configured = readXcconfig(xcconfig)
  // The README is the authority for its own previous version: a re-run after a
  // partial failure must not look for a version the README never carried.
  const advertised = readmeVersion(readme)
  const { version, build } = options
  requireMatch(version, /^\d+\.\d+\.\d+$/, 'version')
  requireMatch(build, /^\d+$/, 'build')

  // A release that cannot reach its users is refused before anything is
  // rewritten, not after the DMG has been built.
  const regression = releaseRegression({
    version,
    build,
    currentVersion: configured.version,
    currentBuild: Number(configured.build),
    publishedBuild: highestPublishedBuild(appcast),
  })
  if (regression !== null) throw new Error(regression)

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
  // A release-notes path is a path, and paths contain spaces. The file is read
  // with the string as it arrives, so `readFileSync`'s own error is the check;
  // a "no whitespace" pattern would only reject valid paths, and it would do it
  // after the DMG had already been built and signed.
  const notesFile = options['notes-file']
  if (typeof notesFile !== 'string' || notesFile.length === 0) {
    throw new Error('release notes file is missing or malformed: ' + JSON.stringify(notesFile))
  }
  const notes = fs.readFileSync(notesFile, 'utf8')
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
  const next = upsertAppcastItem(appcast, item, { version, build })
  if (next === appcast) {
    console.log(`appcast already carries ${version} (build ${build}), length ${length}`)
    return 0
  }
  return report(options.mode, paths.appcast, next, `${version} build ${build}, length ${length}`)
}

/**
 * Report the artifact one version and build has in a feed.
 *
 * Exits 0 and prints `length=`/`url=` when the feed carries it, non-zero when it
 * does not. `release-prepare.sh` runs this against `origin/main` before it
 * builds anything: a build that is already public must never be rebuilt, because
 * the DMG — and the signature the public feed advertises for it — would then
 * stop describing the bytes a client downloads.
 */
function runPublished({ options, paths }) {
  const appcast = fs.readFileSync(options.appcast ?? paths.appcast, 'utf8')
  const version = requireMatch(options.version, /^\d+\.\d+\.\d+$/, 'version')
  const build = requireMatch(options.build, /^\d+$/, 'build')
  const found = publishedItem(appcast, { version, build })
  if (found === null) {
    console.log(`not published: ${version} (build ${build})`)
    return 1
  }
  console.log(`length=${found.length}`)
  console.log(`url=${found.url}`)
  // The signature is what Sparkle actually verifies, and the caller passes it
  // on to the asset check: a length alone cannot tell two same-sized files
  // apart, so a release that is already public is only really proven by
  // verifying the bytes against this.
  console.log(`signature=${found.signature}`)
  return 0
}

/**
 * Check a release before anything is rewritten or built.
 *
 * The release script runs this in preflight so a version that moves backwards,
 * or a build Sparkle would ignore, fails in seconds instead of after a DMG has
 * been produced and signed.
 */
function runGuard({ options, paths }) {
  const configured = readXcconfig(fs.readFileSync(paths.xcconfig, 'utf8'))
  const publishedBuild = highestPublishedBuild(fs.readFileSync(paths.appcast, 'utf8'))
  const version = requireMatch(options.version, /^\d+\.\d+\.\d+$/, 'version')
  const build = requireMatch(options.build, /^\d+$/, 'build')
  const regression = releaseRegression({
    version,
    build,
    currentVersion: configured.version,
    currentBuild: Number(configured.build),
    publishedBuild,
  })
  if (regression !== null) throw new Error(regression)
  console.log(
    `release ${version} (build ${build}) is newer than ${configured.version} (build ${configured.build}) ` +
      `and the newest published build ${publishedBuild}`
  )
  return 0
}

function main() {
  const { command, options } = parseArguments(process.argv.slice(2))
  const paths = defaultPaths
  switch (command) {
    case 'guard':
      return runGuard({ options, paths })
    case 'bump':
      return runBump({ options, paths })
    case 'appcast':
      return runAppcast({ options, paths })
    case 'published':
      return runPublished({ options, paths })
    case 'show':
      console.log(JSON.stringify({ ...readXcconfig(fs.readFileSync(paths.xcconfig, 'utf8')), newest: newestItem(fs.readFileSync(paths.appcast, 'utf8')).trim() }, null, 2))
      return 0
    default:
      throw new Error(`unknown command: ${command ?? '(none)'} (guard | bump | appcast | published | show)`)
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
