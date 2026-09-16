import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// `release-prepare.sh` is the only place that rewrites release state, publishes
// a tag and creates a GitHub release. Those steps cannot run in a test, so the
// conventions they must keep are pinned here: an explicit `git add` list, the
// tag-shaped release title, and the length/signature invariant.

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const script = fs.readFileSync(
  path.join(repositoryDirectory, 'scripts', 'release-prepare.sh'),
  'utf8',
)

test('the release script is valid bash and refuses to run without arguments', () => {
  const syntax = spawnSync('bash', ['-n', path.join(repositoryDirectory, 'scripts', 'release-prepare.sh')])
  assert.equal(syntax.status, 0, syntax.stderr?.toString())

  const usage = spawnSync('bash', [path.join(repositoryDirectory, 'scripts', 'release-prepare.sh')], {
    encoding: 'utf8',
  })
  assert.equal(usage.status, 2)
  assert.match(usage.stderr, /Usage: bash scripts\/release-prepare\.sh/)
})

test('the release script never stages the whole tree', () => {
  assert.doesNotMatch(script, /git add (\.|-A|--all)/)
  assert.match(script, /git add Version\.xcconfig README\.md appcast-swift\.xml/)
  // The local docs directory is deliberately untracked and must not be swept in.
  assert.doesNotMatch(script, /\bdocs\//)
})

test('the release script publishes only on request and keeps the tag shape', () => {
  assert.match(script, /--publish\) publish=true/)
  assert.match(script, /if ! \$publish; then/)
  assert.match(script, /gh release create "\$tag" --title "\$tag" --notes-file "\$notes_file" "\$dmg"/)
  assert.match(script, /tag="v\$version"/)
  // The title is the bare tag: no product name, no prefix.
  assert.doesNotMatch(script, /--title "[^"]*DSH[^"]*"/)
})

test('the feed describes the exact bytes that get uploaded', () => {
  assert.match(script, /length="\$\(stat -f%z "\$dmg"\)"/)
  assert.match(script, /sign_update" --account "\$sparkle_account" "\$dmg"/)
  assert.match(
    script,
    /sign_update reports length \$signed_length but the DMG is \$length bytes/,
    'the signature length is compared with the artifact before the feed is written',
  )
  // The appcast is written after the artifact exists, and the consistency test
  // then re-reads the committed result.
  assert.match(script, /release-metadata\.mjs" appcast \\/)
  assert.match(script, /node --test "\$repository_directory\/test\/swift-release-consistency\.test\.js"/)
})

test('the release script guards the state it is about to rewrite', () => {
  assert.match(script, /working tree has uncommitted tracked changes/)
  assert.match(script, /releases are cut from main/)
  assert.match(script, /main is not up to date with origin\/main/)
  assert.match(script, /tag \$tag already exists/)
  assert.match(script, /releases are built on Apple Silicon only/)
  assert.match(script, /--dry-run\) dry_run=true/)
})
