import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// The release checklist edits four files by hand — `Version.xcconfig`, the
// three README spots, and the appcast item — and a release commit is only
// consistent when they agree. These assertions derive everything from
// `Version.xcconfig`, so a half-finished bump fails here instead of shipping a
// feed that points at the previous build or a README that downloads the
// previous DMG.

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const read = (relative) => fs.readFileSync(path.join(repositoryDirectory, relative), 'utf8')
const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

function xcconfigValue(source, name) {
  const match = source.match(new RegExp(`^\\s*${name}\\s*=\\s*(\\S+)\\s*$`, 'm'))
  assert.ok(match, `Version.xcconfig must define ${name}`)
  return match[1]
}

function newestAppcastItem(appcast) {
  const start = appcast.indexOf('<item>')
  const end = appcast.indexOf('</item>', start)
  assert.ok(start >= 0 && end > start, 'the appcast must publish at least one item')
  return appcast.slice(start, end)
}

const xcconfig = read('Version.xcconfig')
const version = xcconfigValue(xcconfig, 'SWIFT_APP_VERSION')
const build = xcconfigValue(xcconfig, 'SWIFT_APP_BUILD')
const tag = `v${version}`

test('the bundle takes its version from the release metadata', () => {
  assert.match(xcconfig, /^MARKETING_VERSION = \$\(SWIFT_APP_VERSION\)$/m)
  assert.match(xcconfig, /^CURRENT_PROJECT_VERSION = \$\(SWIFT_APP_BUILD\)$/m)

  // Info.plist must not pin a literal version: the two build settings above are
  // what the released bundle carries.
  const plist = read('Info.plist')
  assert.match(
    plist,
    /<key>CFBundleShortVersionString<\/key>\s*<string>\$\(MARKETING_VERSION\)<\/string>/,
  )
  assert.match(
    plist,
    /<key>CFBundleVersion<\/key>\s*<string>\$\(CURRENT_PROJECT_VERSION\)<\/string>/,
  )
})

test('every README release reference names the current version', () => {
  const readme = read('README.md')

  const tags = [...readme.matchAll(/releases\/tag\/(v[\d.]+)/g)].map((match) => match[1])
  assert.ok(tags.length >= 2, `the README links the release tag at least twice, saw ${tags.length}`)
  for (const found of tags) {
    assert.equal(found, tag, `a README release link still names ${found}`)
  }

  const badges = [...readme.matchAll(/badge\/Swift%20Native-(v[\d.]+)-/g)].map((match) => match[1])
  assert.deepEqual(badges, [tag], `the README version badge names ${badges.join(', ') || 'nothing'}`)

  const downloads = [
    ...readme.matchAll(/releases\/download\/(v[\d.]+)\/(DSH-Desktop-[\d.]+-arm64\.dmg)/g),
  ]
  assert.equal(downloads.length, 1, 'the README offers exactly one DMG download')
  assert.equal(downloads[0][1], tag, `the download link points at ${downloads[0][1]}`)
  assert.equal(
    downloads[0][2],
    `DSH-Desktop-${version}-arm64.dmg`,
    'the DMG file name must carry the same version',
  )
})

test('the newest appcast item publishes the current build', () => {
  const newest = newestAppcastItem(read('appcast-swift.xml'))

  assert.match(newest, new RegExp(`<title>${escapeRegExp(version)}</title>`))
  assert.match(newest, new RegExp(`<sparkle:shortVersionString>${escapeRegExp(version)}</sparkle:shortVersionString>`))
  assert.match(newest, new RegExp(`<sparkle:version>${escapeRegExp(build)}</sparkle:version>`))
  assert.match(newest, new RegExp(`releases/tag/${escapeRegExp(tag)}<`))
  assert.match(
    newest,
    new RegExp(`releases/download/${escapeRegExp(tag)}/DSH-Desktop-${escapeRegExp(version)}-arm64\\.dmg`),
  )
  // Sparkle refuses an item without an archive length and an EdDSA signature.
  assert.match(newest, /<enclosure[^>]*\slength="\d+"/)
  assert.match(newest, /sparkle:edSignature="[A-Za-z0-9+/=]{40,}"/)
})

test('the appcast advertises a system and architecture the bundle can run on', () => {
  const newest = newestAppcastItem(read('appcast-swift.xml'))
  const project = read(path.join('DSH.xcodeproj', 'project.pbxproj'))

  const deploymentTargets = new Set(
    [...project.matchAll(/MACOSX_DEPLOYMENT_TARGET = ([\d.]+);/g)].map((match) => match[1]),
  )
  assert.equal(deploymentTargets.size, 1, `one deployment target, saw ${[...deploymentTargets]}`)
  const [deploymentTarget] = deploymentTargets
  assert.match(
    newest,
    new RegExp(`<sparkle:minimumSystemVersion>${escapeRegExp(deploymentTarget)}</sparkle:minimumSystemVersion>`),
    'an update must not be offered to a macOS version the bundle refuses to launch on',
  )
  assert.match(
    newest,
    /<sparkle:hardwareRequirements>arm64<\/sparkle:hardwareRequirements>/,
    'the shell is arm64-only',
  )
})
