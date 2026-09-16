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
  // One array, used by both the instructions and the publish step, so the two
  // cannot drift apart.
  assert.match(script, /release_files=\(Version\.xcconfig README\.md appcast-swift\.xml\)/)
  assert.match(script, /git add "\$\{release_files\[@\]\}"/)
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
  assert.match(script, /uncommitted changes outside the release files/)
  assert.match(script, /releases are cut from main/)
  assert.match(script, /has diverged from origin\/main/)
  assert.match(script, /already exists on another commit/)
  assert.match(script, /releases are built on Apple Silicon only/)
  assert.match(script, /--dry-run\) dry_run=true/)
})

test('the signing tool is taken out of .build before the packager deletes it', () => {
  // `build-app.sh` creates the Sparkle checkout under `.build`, and
  // `package-dmg.sh` deletes `.build` once the DMG verifies. Looking for
  // sign_update after running both can only ever fail.
  const build = script.indexOf('bash "$repository_directory/scripts/build-app.sh"')
  const copy = script.indexOf('cp "$sign_update_source" "$sign_update"')
  const packageIt = script.indexOf('bash "$repository_directory/scripts/package-dmg.sh"')
  assert.ok(build > 0 && copy > build && packageIt > copy, 'order must be build → copy sign_update → package')
  assert.doesNotMatch(script, /release-local\.sh/)

  const packager = fs.readFileSync(
    path.join(repositoryDirectory, 'scripts', 'package-dmg.sh'),
    'utf8',
  )
  assert.match(packager, /rm -rf "\$\{BUILD_DIR\}"/, 'the packager does delete the build directory')
})

test('the feed goes public only after the uploaded bytes are verified', () => {
  const publish = script.slice(script.indexOf('step "Publish"'))
  assert.ok(publish.length > 0)
  const tagPush = publish.indexOf('git push origin "$tag"')
  const release = publish.indexOf('gh release create')
  const verify = publish.indexOf('release-verify-asset.sh" "$tag" "$dmg" "$digest"')
  const mainPush = publish.indexOf('git push origin main')
  assert.ok(
    tagPush > 0 && release > tagPush && verify > release && mainPush > verify,
    'order must be tag → release upload → verification → main (which carries the feed)',
  )

  // The verification is a script of its own, so the prepare-only flow can hand
  // the operator the exact command and a published release can be re-checked.
  const verifier = fs.readFileSync(
    path.join(repositoryDirectory, 'scripts', 'release-verify-asset.sh'),
    'utf8',
  )
  assert.match(verifier, /gh release download "\$tag" --pattern "\$name"/)
  assert.match(verifier, /hashes to \$uploaded_digest, expected \$expected_digest/)
  assert.match(verifier, /uploaded \$name is \$uploaded_size bytes, expected \$local_size/)
  assert.match(
    script,
    /bash scripts\/release-verify-asset\.sh \$tag "\$dmg" \$digest/,
    'the prepare-only instructions print a command that actually exists',
  )
})

test('a release that died halfway can be resumed', () => {
  // prepare rewrites these three files, so a re-run sees them dirty; anything
  // else dirty is what the check exists for.
  assert.match(script, /release_files=\(Version\.xcconfig README\.md appcast-swift\.xml\)/)
  assert.match(script, /uncommitted changes outside the release files: \$path/)
  // A tag from the failed attempt must be reused, never moved.
  assert.match(script, /resuming: tag \$tag already points at HEAD/)
  assert.match(script, /refusing to move it/)
  assert.match(script, /git merge-base --is-ancestor origin\/main HEAD/)
  // Each publish step tolerates having already happened.
  assert.match(script, /if git diff --cached --quiet; then/)
  assert.match(script, /release commit already exists/)
  assert.match(script, /gh release upload "\$tag" "\$dmg" --clobber/)
})

test('the verify script guards its own inputs', () => {
  const verifierPath = path.join(repositoryDirectory, 'scripts', 'release-verify-asset.sh')
  const syntax = spawnSync('bash', ['-n', verifierPath])
  assert.equal(syntax.status, 0, syntax.stderr?.toString())

  const usage = spawnSync('bash', [verifierPath], { encoding: 'utf8' })
  assert.equal(usage.status, 2)
  assert.match(usage.stderr, /Usage: bash scripts\/release-verify-asset\.sh/)

  const missing = spawnSync('bash', [verifierPath, 'v1.2.5', '/nonexistent.dmg', 'a'.repeat(64)], {
    encoding: 'utf8',
  })
  assert.equal(missing.status, 1)
  assert.match(missing.stderr, /the local artifact does not exist/)
})

test('the release script refuses a release Sparkle could never deliver', () => {
  assert.match(script, /release-metadata\.mjs" guard --version "\$version" --build "\$build"/)
  const guard = script.indexOf('release-metadata.mjs" guard')
  const bump = script.indexOf('release-metadata.mjs" bump')
  assert.ok(guard > 0 && bump > guard, 'the guard runs before anything is rewritten')
})
