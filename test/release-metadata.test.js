import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  buildAppcastItem,
  bumpReadme,
  bumpXcconfig,
  defaultPaths,
  insertAppcastItem,
  newestItem,
  readXcconfig,
  readmeVersion,
  rfc822,
} from '../scripts/release-metadata.mjs'

// `rfc822` is the local-zone timestamp Sparkle shows in the feed; pin the zone
// so the assertion is about the formatter, not about this machine.
process.env.TZ = 'UTC'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')

const xcconfigFixture = `// Swift shell release metadata.
SWIFT_APP_VERSION = 1.2.5
SWIFT_APP_BUILD = 16
MARKETING_VERSION = $(SWIFT_APP_VERSION)
CURRENT_PROJECT_VERSION = $(SWIFT_APP_BUILD)
`

const readmeFixture = `
<a href="https://github.com/summer-521/deepseek-harness-swift/releases/tag/v1.2.5"><img alt="Swift 原生版 v1.2.5" src="https://img.shields.io/badge/Swift%20Native-v1.2.5-171513.svg" /></a>
发布在 [DSH Desktop Releases](https://github.com/summer-521/deepseek-harness-swift/releases/tag/v1.2.5)。
| macOS | Apple Silicon | DMG | [下载 arm64](https://github.com/summer-521/deepseek-harness-swift/releases/download/v1.2.5/DSH-Desktop-1.2.5-arm64.dmg) |
`

const appcastFixture = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>DSH Swift Updates</title>
        <link>https://github.com/summer-521/deepseek-harness-swift/releases</link>
        <description>Updates for the native Swift shell of DSH Desktop.</description>
        <language>zh-CN</language>
        <item>
            <title>1.2.5</title>
            <sparkle:version>16</sparkle:version>
            <sparkle:shortVersionString>1.2.5</sparkle:shortVersionString>
            <enclosure url="https://github.com/summer-521/deepseek-harness-swift/releases/download/v1.2.5/DSH-Desktop-1.2.5-arm64.dmg" length="1" type="application/octet-stream" sparkle:edSignature="AAAA"/>
        </item>
    </channel>
</rss>
`

const notesFixture = `## 修复

- 一件修复。
`

function item({ version = '1.2.6', build = '17', ...overrides } = {}) {
  return buildAppcastItem({
    version,
    build,
    url: `https://github.com/summer-521/deepseek-harness-swift/releases/download/v${version}/DSH-Desktop-${version}-arm64.dmg`,
    length: '50425442',
    signature: '6Fpuqv3YdnFlA2Hx8C9tJ1M9LnQHyDi99A0vbhTRcI/637Kivw8t+ccS6DAuUe1/hIxOyw7F5cJX8J83X/PbBA==',
    notes: notesFixture,
    publishedAt: new Date('2026-09-16T01:00:00Z'),
    minimumSystemVersion: '26.0',
    ...overrides,
  })
}

test('the timestamp keeps the feed format Sparkle parses', () => {
  assert.equal(rfc822(new Date('2026-09-15T13:15:13Z')), 'Tue, 15 Sep 2026 13:15:13 +0000')
  assert.equal(rfc822(new Date('2026-01-02T03:04:05Z')), 'Fri, 02 Jan 2026 03:04:05 +0000')
})

test('the bump moves the config and all three README references together', () => {
  assert.deepEqual(readXcconfig(xcconfigFixture), { version: '1.2.5', build: '16' })
  assert.equal(readmeVersion(readmeFixture), '1.2.5')

  const nextConfig = bumpXcconfig(xcconfigFixture, { version: '1.2.6', build: '17' })
  assert.match(nextConfig, /^SWIFT_APP_VERSION = 1\.2\.6$/m)
  assert.match(nextConfig, /^SWIFT_APP_BUILD = 17$/m)
  assert.match(nextConfig, /^MARKETING_VERSION = \$\(SWIFT_APP_VERSION\)$/m)
  assert.equal(readXcconfig(nextConfig).version, '1.2.6')

  const { source: nextReadme, replacements } = bumpReadme(readmeFixture, {
    previousVersion: '1.2.5',
    version: '1.2.6',
  })
  assert.equal(replacements.tag, 2)
  assert.equal(replacements.badge, 1)
  assert.equal(replacements.badgeText, 1)
  assert.equal(replacements.download, 1)
  assert.doesNotMatch(nextReadme, /v1\.2\.5/)
  assert.match(nextReadme, /releases\/tag\/v1\.2\.6/)
  assert.match(nextReadme, /badge\/Swift%20Native-v1\.2\.6-/)
  assert.match(nextReadme, /Swift 原生版 v1\.2\.6/)
  assert.match(nextReadme, /releases\/download\/v1\.2\.6\/DSH-Desktop-1\.2\.6-arm64\.dmg/)
  assert.equal(readmeVersion(nextReadme), '1.2.6')
})

test('a bump refuses a config or README that has no version to move', () => {
  assert.throws(() => readXcconfig('SWIFT_APP_VERSION = 1.2.5\n'), /SWIFT_APP_BUILD/)
  assert.throws(() => bumpXcconfig('SWIFT_APP_VERSION = 1.2.5\nSWIFT_APP_BUILD = 16\nSWIFT_APP_BUILD = 15\n', {
    version: '1.2.6',
    build: '17',
  }), /SWIFT_APP_BUILD/)
  assert.throws(() => readmeVersion('no download link here'), /download link/)
  assert.throws(() => bumpReadme('no references', { previousVersion: '1.2.5', version: '1.2.6' }), /tag reference/)
})

test('an appcast item carries everything Sparkle needs', () => {
  const built = item()
  assert.match(built, /<title>1\.2\.6<\/title>/)
  assert.match(built, /<pubDate>Wed, 16 Sep 2026 01:00:00 \+0000<\/pubDate>/)
  assert.match(built, /releases\/tag\/v1\.2\.6<\/link>/)
  assert.match(built, /<sparkle:version>17<\/sparkle:version>/)
  assert.match(built, /<sparkle:shortVersionString>1\.2\.6<\/sparkle:shortVersionString>/)
  assert.match(built, /<sparkle:minimumSystemVersion>26\.0<\/sparkle:minimumSystemVersion>/)
  assert.match(built, /<sparkle:hardwareRequirements>arm64<\/sparkle:hardwareRequirements>/)
  assert.match(built, /<description sparkle:format="markdown"><!\[CDATA\[\n## 修复\n\n- 一件修复。\n\]\]><\/description>/)
  assert.match(built, /length="50425442"/)
  assert.match(built, /sparkle:edSignature="6Fpuqv3YdnFlA2Hx8C9tJ1M9LnQHyDi99A0vbhTRcI\/637Kivw8t\+ccS6DAuUe1\/hIxOyw7F5cJX8J83X\/PbBA=="/)
})

test('an appcast item rejects what Sparkle would refuse or misread', () => {
  assert.throws(() => item({ version: 'v1.2.6' }), /version/)
  assert.throws(() => item({ build: '17.1' }), /build/)
  assert.throws(() => item({ length: '0' }), /archive length/)
  assert.throws(() => item({ signature: 'short' }), /signature/)
  assert.throws(() => item({ notes: '   ' }), /empty/)
  assert.throws(() => item({ notes: 'bad ]]> notes' }), /CDATA/)
  assert.throws(
    () => item({ url: 'https://example.test/other.dmg' }),
    /does not address the 1\.2\.6 arm64 DMG/,
  )
  assert.throws(() => item({ minimumSystemVersion: 'macOS 26' }), /minimum system version/)
})

test('a new release becomes the newest item and never duplicates one', () => {
  const inserted = insertAppcastItem(appcastFixture, item(), { version: '1.2.6', build: '17' })
  const newest = newestItem(inserted)
  assert.match(newest, /<title>1\.2\.6<\/title>/)
  assert.ok(
    inserted.indexOf('<title>1.2.6</title>') < inserted.indexOf('<title>1.2.5</title>'),
    'the inserted item must come before the previous release',
  )
  assert.match(inserted, /<language>zh-CN<\/language>\n        <item>\n            <title>1\.2\.6<\/title>/)
  // The previous item survives untouched.
  assert.match(inserted, /<title>1\.2\.5<\/title>/)

  assert.throws(
    () => insertAppcastItem(inserted, item(), { version: '1.2.6', build: '17' }),
    /already publishes 1\.2\.6/,
  )
  assert.throws(
    () => insertAppcastItem(inserted, item({ version: '1.2.7' }), { version: '1.2.7', build: '17' }),
    /already publishes/,
    'a reused build number is still a duplicate release',
  )
  assert.throws(() => insertAppcastItem('<rss></rss>', item(), { version: '1.2.6', build: '17' }), /channel/)
})

test('write mode produces a release whose metadata agrees end to end', () => {
  // The CLI resolves its files from the script location, so a copy of the
  // script and the three release files in a temp tree exercises the real write
  // path without touching the repository's release state.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-release-metadata-'))
  try {
    fs.mkdirSync(path.join(root, 'scripts'))
    fs.copyFileSync(
      path.join(repositoryDirectory, 'scripts', 'release-metadata.mjs'),
      path.join(root, 'scripts', 'release-metadata.mjs'),
    )
    fs.writeFileSync(path.join(root, 'Version.xcconfig'), xcconfigFixture)
    fs.writeFileSync(path.join(root, 'README.md'), readmeFixture)
    fs.writeFileSync(path.join(root, 'appcast-swift.xml'), appcastFixture)
    const notes = path.join(root, 'notes.md')
    fs.writeFileSync(notes, notesFixture)
    const run = (...args) => spawnSync(
      process.execPath,
      [path.join(root, 'scripts', 'release-metadata.mjs'), ...args],
      { encoding: 'utf8' },
    )
    const signature = 'A'.repeat(64)

    const bump = run('bump', '--version', '1.2.6', '--build', '17', '--write')
    assert.equal(bump.status, 0, bump.stderr || bump.stdout)
    const write = run(
      'appcast', '--version', '1.2.6', '--build', '17',
      '--length', '50425442', '--signature', signature,
      '--notes-file', notes, '--write',
    )
    assert.equal(write.status, 0, write.stderr || write.stdout)

    assert.deepEqual(
      readXcconfig(fs.readFileSync(path.join(root, 'Version.xcconfig'), 'utf8')),
      { version: '1.2.6', build: '17' },
    )
    const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8')
    assert.equal(readmeVersion(readme), '1.2.6')
    const newest = newestItem(fs.readFileSync(path.join(root, 'appcast-swift.xml'), 'utf8'))
    assert.match(newest, /<title>1\.2\.6<\/title>/)
    assert.match(newest, /<sparkle:version>17<\/sparkle:version>/)
    assert.match(newest, /releases\/tag\/v1\.2\.6<\/link>/)
    assert.match(newest, /releases\/download\/v1\.2\.6\/DSH-Desktop-1\.2\.6-arm64\.dmg/)

    // A second run must refuse to publish the same release twice, and the bump
    // must be idempotent so a re-run after a partial failure is safe.
    const again = run(
      'appcast', '--version', '1.2.6', '--build', '17',
      '--length', '50425442', '--signature', signature,
      '--notes-file', notes, '--write',
    )
    assert.equal(again.status, 2, again.stderr || again.stdout)
    assert.match(again.stderr, /already publishes 1\.2\.6/)
    const rebump = run('bump', '--version', '1.2.6', '--build', '17', '--write')
    assert.equal(rebump.status, 0, rebump.stderr || rebump.stdout)
    assert.match(rebump.stdout, /already at 1\.2\.6 \(build 17\)/)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('check mode reports without rewriting the release files', () => {
  const before = new Map(
    Object.entries(defaultPaths).map(([name, file]) => [name, fs.readFileSync(file, 'utf8')]),
  )
  const bump = spawnSync(process.execPath, [
    path.join(repositoryDirectory, 'scripts', 'release-metadata.mjs'),
    'bump', '--version', '9.9.9', '--build', '99',
  ], { encoding: 'utf8' })
  assert.equal(bump.status, 1, bump.stderr || bump.stdout)
  assert.match(bump.stdout, /would update Version\.xcconfig/)

  const appcast = spawnSync(process.execPath, [
    path.join(repositoryDirectory, 'scripts', 'release-metadata.mjs'),
    'appcast', '--version', '9.9.9', '--build', '99',
    '--length', '123', '--notes-file', path.join(testDirectory, 'swift-app-update.test.js'),
    '--signature', 'A'.repeat(64),
  ], { encoding: 'utf8' })
  assert.equal(appcast.status, 1, appcast.stderr || appcast.stdout)
  assert.match(appcast.stdout, /would update appcast-swift\.xml/)

  for (const [name, file] of Object.entries(defaultPaths)) {
    assert.equal(fs.readFileSync(file, 'utf8'), before.get(name), `${name} must not change in check mode`)
  }
})
