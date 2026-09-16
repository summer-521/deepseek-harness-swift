import assert from 'node:assert/strict'
import test from 'node:test'

import {
  assertCalls,
  assertNeverCalls,
  callPattern,
  countCalls,
  functionBody,
  sliceBetween,
} from './source-assertions.mjs'

test('countCalls ignores arguments the caller adds later', () => {
  const source = [
    'restartService(context: context)',
    'restartService(context: context, progress: handler)',
    'restartService(context: other)',
    'restartService(  context: context)',
    // A text scanner cannot tell code from a string literal, so this line
    // counts too; the assertions that use the helper point at code, where that
    // is not a source of surprise.
    'let label = "restartService(context: context)"',
  ].join('\n')

  // The regression this exists for: a parameter added to the callee must not
  // change the count of its call sites.
  assert.equal(countCalls(source, 'restartService'), 5)
  assert.equal(
    countCalls(source, 'restartService', { firstArgument: /context: context\b/ }),
    4,
    'only the calls that start with the expected first argument',
  )
  assert.equal(
    countCalls(source, 'restartService', { firstArgument: 'context: other' }),
    1,
  )
  assert.equal(countCalls(source, 'restartServiceWithRecovery'), 0, 'a longer name is a different call')
})

test('the call assertions report presence and absence without pinning arguments', () => {
  const source = 'try await restart(context: context, progress: bridge)'
  assertCalls(source, 'restart', 'restart must be called')
  assertNeverCalls(source, 'restartDuringOperation', 'the direct restart must not be used')
  assert.throws(() => assertCalls(source, 'reboot'), /reboot/)
  assert.throws(() => assertNeverCalls(source, 'restart'), /restart/)
  assert.match('restart(context: context)', callPattern('restart'))
})

test('functionBody returns one balanced body, not the rest of the file', () => {
  const source = [
    'final class Example {',
    '    func outer(context: Context) {',
    '        if true {',
    '            print("}")',
    '        }',
    '    }',
    '    func other() {}',
    '}',
  ].join('\n')

  const body = functionBody(source, 'func outer(context: Context)')
  assert.ok(body.startsWith('{'))
  assert.ok(body.endsWith('}'))
  assert.equal(body.match(/\{/g).length, body.match(/\}/g).length)
  assert.doesNotMatch(body, /func other/)

  assert.throws(() => functionBody(source, 'func missing()'), /does not contain/)
})

test('sliceBetween fails loudly when an anchor is renamed', () => {
  const source = 'public func setAppProfile() {\n    // end\n}'
  assert.equal(sliceBetween(source, 'public func setAppProfile', '// end'), 'public func setAppProfile() {\n    ')
  assert.throws(() => sliceBetween(source, 'public func setProfile', '// end'), /does not contain/)
  assert.throws(() => sliceBetween(source, 'public func setAppProfile', '// missing'), /does not contain \/\/ missing/)
})
