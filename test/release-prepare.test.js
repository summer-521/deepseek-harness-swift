import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
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
  assert.match(script, /gh release create \$tag --title \$tag --notes-file \$quoted_notes \$quoted_dmg/)
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
  const verify = publish.indexOf('release-verify-asset.sh" \\\n\t"$tag" "$dmg" "$digest" --signature "$signature"')
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
    /bash scripts\/release-verify-asset\.sh \$tag \$quoted_dmg \$digest --signature '\$signature'/,
    'the prepare-only instructions print a command that actually exists',
  )
})

test('the published bytes are proven against the signature clients verify', () => {
  const verifier = fs.readFileSync(
    path.join(repositoryDirectory, 'scripts', 'release-verify-asset.sh'),
    'utf8',
  )
  // A length cannot tell two same-sized files apart, and Sparkle verifies the
  // EdDSA signature: a published release is only proven by checking the bytes.
  assert.match(verifier, /\[\[ -n "\$signature" \]\] \\\n\s*\|\| fail "--feed needs --signature/)
  assert.match(verifier, /verifySignature "\$downloaded"/)
  // The local artifact is checked before anything is downloaded: an artifact
  // that cannot satisfy the feed's signature must not be uploaded at all.
  const localSection = verifier.slice(verifier.indexOf('local_dmg="$subject"'))
  const localCheck = localSection.indexOf('verifySignature "$local_dmg"')
  const download = localSection.indexOf('gh release download "$tag"')
  assert.ok(localCheck > 0 && download > localCheck, 'the local artifact is verified first')

  // The key is the one the app ships, so this answers "would Sparkle accept it".
  const wrapper = fs.readFileSync(
    path.join(repositoryDirectory, 'scripts', 'verify-sparkle-signature.sh'),
    'utf8',
  )
  assert.match(wrapper, /plutil -extract SUPublicEDKey raw -o - "\$info_plist"/)
  assert.match(wrapper, /scripts\/sparkle-signature\.swift/)
  const verifierSource = fs.readFileSync(
    path.join(repositoryDirectory, 'scripts', 'sparkle-signature.swift'),
    'utf8',
  )
  assert.match(verifierSource, /Curve25519\.Signing\.PublicKey\(rawRepresentation:/)
  assert.match(verifierSource, /isValidSignature\(signature, for: fileData\)/)
  // Ed25519 verification of a real artifact is exercised by the wrapper's own
  // tests; what matters here is that nothing weaker stands in for it.
  assert.doesNotMatch(verifier, /shasum[^\n]*--signature/)
})

test('the prepare-only instructions quote the paths they print', () => {
  // The printed commands are meant to be pasted. A notes file under a path with
  // a space would otherwise arrive as several arguments.
  assert.match(script, /printf -v quoted_notes '%q' "\$notes_file"/)
  assert.match(script, /printf -v quoted_dmg '%q' "\$dmg"/)
  const instructions = script.match(/cat <<EOF\n([\s\S]*?)\nEOF\n/)?.[1] ?? ''
  assert.ok(instructions.length > 0, 'the remaining steps are printed from a heredoc')
  assert.doesNotMatch(
    instructions,
    /\$notes_file|\$dmg\b/,
    'every printed path must go through the quoted form',
  )
  assert.match(instructions, /\$quoted_notes/)
  assert.match(instructions, /\$quoted_dmg/)
})

test('a release that died halfway can be resumed', () => {
  // prepare rewrites these three files, so a re-run sees them dirty; anything
  // else dirty is what the check exists for.
  assert.match(script, /release_files=\(Version\.xcconfig README\.md appcast-swift\.xml\)/)
  assert.match(script, /uncommitted changes outside the release files: \$path/)
  // A tag from the failed attempt must be reused, never moved — and only when it
  // already describes this exact release: anything the publish step would still
  // commit moves HEAD past the tag.
  assert.match(script, /resuming: tag \$tag already points at HEAD and describes \$version/)
  assert.match(script, /refusing to move it/)
  assert.match(script, /tag \$tag exists but \$\{release_files\[\*\]\} have uncommitted changes/)
  assert.match(script, /tag \$tag exists but Version\.xcconfig\/README do not describe \$version/)
  assert.match(script, /git merge-base --is-ancestor origin\/main HEAD/)
  // Each publish step tolerates having already happened.
  assert.match(script, /if git diff --cached --quiet; then/)
  assert.match(script, /release commit already exists/)
  assert.match(script, /gh release upload "\$tag" "\$dmg" --clobber/)
})

test('creating the release commit re-checks the tag before anything is pushed', () => {
  const publish = script.slice(script.indexOf('step "Publish"'))
  const commit = publish.indexOf('git commit -m "release: prepare')
  const tagCheck = publish.indexOf('tag $tag points at ')
  const tagPush = publish.indexOf('git push origin "$tag"')
  assert.ok(commit > 0 && tagCheck > commit, 'the tag is compared with HEAD after the commit')
  assert.ok(tagPush > tagCheck, 'and before the tag is pushed')
  // The message must not claim the tag matches when it does not.
  assert.match(
    publish,
    /\[\[ "\$tag_commit" == "\$\(git rev-parse HEAD\)" \]\]/,
    'the comparison is an equality test, not an existence test',
  )
})

test('a version that is already public is never rebuilt', () => {
  // A push can succeed remotely and fail locally; re-running the release would
  // then rebuild the DMG and upload bytes under the signature the public feed
  // still advertises.
  assert.match(script, /git show origin\/main:appcast-swift\.xml/)
  assert.match(script, /published \\\n\s*--version "\$version" --build "\$build" --appcast/)
  const published = script.indexOf('step "$tag is already published"')
  const build = script.indexOf('bash "$repository_directory/scripts/build-app.sh"')
  assert.ok(published > 0 && build > published, 'the check runs before anything is built')
  // Already public means: verify what the feed advertises, change nothing, stop.
  const branch = script.slice(published, build)
  assert.match(branch, /release-verify-asset\.sh" \\\n\s*--feed "\$tag" "\$published_url" "\$published_length"/)
  assert.match(branch, /exit 0/)
  assert.doesNotMatch(branch, /gh release upload|git push/)
  // A dry run answers the question without downloading the published artifact.
  assert.match(branch, /if \$dry_run; then[\s\S]*?exit 0\s*\n\s*fi/)
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

test('a pushed tag whose release failed is resumed from the artifact it names', () => {
  // Pushing the tag and creating the GitHub release are separate steps: when the
  // second one fails, the tag is already public and cannot move, so a rebuild
  // would produce different bytes under a tag that names the old ones — and the
  // rewrite of the appcast would move HEAD past the tag and stop the release
  // entirely.
  assert.match(script, /if \$resuming_release; then/)
  assert.match(script, /resuming_release=true/)
  // The artifact is identified from the appcast item and proven to be those
  // bytes before anything is built.
  const resumeStart = script.indexOf('if $resuming_release; then')
  const resume = script.slice(resumeStart, script.indexOf('step "Bump release metadata"'))
  assert.ok(resume.length > 0, 'the reuse decision happens in preflight')
  assert.match(resume, /published \\\n\s*--version "\$version" --build "\$build"/)
  assert.match(resume, /resume_length="\$\(sed -nE 's\/\^length=/)
  assert.match(resume, /resume_signature="\$\(sed -nE 's\/\^signature=/)
  assert.match(resume, /verify-sparkle-signature\.sh" "\$resume_signature" "\$dmg"/)
  assert.match(resume, /the artifact it names cannot be identified/)
  assert.match(resume, /which is not on disk; a rebuild would produce different bytes/)
  assert.match(resume, /refusing to rebuild a tagged release/)
  // And the build/sign/appcast steps are skipped when it is reused.
  const reuse = script.indexOf('step "Reuse the artifact this release already built"')
  const build = script.indexOf('step "Build and package"')
  assert.ok(reuse > 0 && build > reuse, 'the reuse branch comes before the build branch')
  assert.match(script.slice(reuse, build), /length="\$resume_length"/)
  const fresh = script.slice(build)
  assert.match(fresh, /verify-sparkle-signature\.sh" "\$signature" "\$dmg"/, 'a fresh artifact is verified too')
  // The consistency test runs either way: it reads the release files, not the build.
  const consistency = script.indexOf('node --test "$repository_directory/test/swift-release-consistency.test.js"')
  assert.ok(consistency > build, 'the consistency test is outside both branches')
})

test('the signature check refuses a file the app key did not sign', () => {
  // The public key is the one this app ships, so this is the same question a
  // client asks when it verifies a download. It runs for real here: the verifier
  // is a Swift program compiled on demand, and a broken one must fail rather
  // than pass everything.
  const wrapper = path.join(repositoryDirectory, 'scripts', 'verify-sparkle-signature.sh')
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-signature-test-'))
  try {
    const artifact = path.join(directory, 'artifact.bin')
    fs.writeFileSync(artifact, 'not the published bytes')

    const bogus = spawnSync('bash', [wrapper, 'A'.repeat(86) + '==', artifact], {
      encoding: 'utf8',
      timeout: 120000,
    })
    assert.equal(bogus.status, 1, bogus.stderr || bogus.stdout)
    assert.match(bogus.stderr, /does not carry the signature/)

    const noKey = spawnSync('bash', [wrapper, 'A'.repeat(86) + '==', artifact, '--info-plist', path.join(directory, 'missing.plist')], {
      encoding: 'utf8',
      timeout: 120000,
    })
    assert.equal(noKey.status, 1)
    assert.match(noKey.stderr, /SUPublicEDKey/)

    const usage = spawnSync('bash', [wrapper], { encoding: 'utf8' })
    assert.equal(usage.status, 2)
    assert.match(usage.stderr, /Usage: bash scripts\/verify-sparkle-signature\.sh/)
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
})
