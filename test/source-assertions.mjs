// Helpers for the source-scanning tests.
//
// Those tests assert on Swift source text because the shell has no Swift test
// target, and the cost of that choice is fragility: an assertion that spells
// out a call's whole argument list goes red the moment a parameter is added.
// That is exactly what happened when
// `restartDshServiceWithAuthenticationRecoveryDuringOperation` gained a
// profile-bridge progress callback and two assertions counted zero call sites
// instead of two, leaving main red until the patterns were relaxed by hand.
//
// The helpers below keep such an assertion's *intent* — this receiver calls
// this function, here, this many times — without pinning the exact call text,
// so a new parameter is a non-event.

import assert from 'node:assert/strict'

const escape = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** Matches a call to `name`, whatever arguments it passes. */
export function callPattern(name) {
  return new RegExp(`${escape(name)}\\s*\\(`)
}

/**
 * Counts call sites of `name`. `firstArgument` (string or RegExp) restricts the
 * count to calls that begin with that argument; anything the callee passes
 * after it is allowed on purpose.
 */
export function countCalls(source, name, { firstArgument } = {}) {
  const prefix = firstArgument === undefined
    ? ''
    : firstArgument instanceof RegExp
      ? `\\s*${firstArgument.source}`
      : `\\s*${escape(firstArgument)}`
  return (source.match(new RegExp(`${escape(name)}\\s*\\(${prefix}`, 'g')) ?? []).length
}

/** Asserts `source` calls `name` at least once. */
export function assertCalls(source, name, message) {
  assert.match(source, callPattern(name), message)
}

/** Asserts `source` never calls `name`. */
export function assertNeverCalls(source, name, message) {
  assert.doesNotMatch(source, callPattern(name), message)
}

/**
 * The body of `declaration`: from the `{` that opens it to the `}` that closes
 * it, so a test can assert on one function without slicing to the next
 * declaration by hand (and without silently swallowing the rest of the file
 * when that declaration is renamed).
 */
export function functionBody(source, declaration) {
  const start = source.indexOf(declaration)
  assert.ok(start >= 0, `source does not contain: ${declaration}`)
  const open = source.indexOf('{', start)
  assert.ok(open >= 0, `no body opens after: ${declaration}`)
  let depth = 0
  for (let index = open; index < source.length; index += 1) {
    const character = source[index]
    if (character === '{') depth += 1
    else if (character === '}') {
      depth -= 1
      if (depth === 0) return source.slice(open, index + 1)
    }
  }
  assert.fail(`unbalanced braces after: ${declaration}`)
}

/** The region from `from` up to (not including) the next `until`. */
export function sliceBetween(source, from, until) {
  const start = source.indexOf(from)
  assert.ok(start >= 0, `source does not contain: ${from}`)
  const end = source.indexOf(until, start + from.length)
  assert.ok(end >= 0, `source does not contain ${until} after ${from}`)
  return source.slice(start, end)
}
