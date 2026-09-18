import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const shell = fs.readFileSync(new URL('../Sources/MainWindow/DshWebShell.swift', import.meta.url), 'utf8')

test('macOS collapsed sidebar follows the official zero-width header-controls layout', () => {
  assert.notEqual(
    shell.indexOf("setAttribute('data-platform', 'darwin')"),
    -1,
    'the WebKit shell must publish the official macOS platform marker',
  )
  const collapsedLayout = shell.indexOf('html[data-platform="darwin"] [data-sidebar-collapsed]')
  assert.notEqual(collapsedLayout, -1, 'the macOS collapsed sidebar must have a dedicated layout override')
  assert.notEqual(
    shell.indexOf('grid-template-columns: 0px minmax(0px, 1fr) 0px !important;', collapsedLayout),
    -1,
    'the macOS collapsed sidebar must leave the full frame to the conversation',
  )

  const hiddenSidebar = shell.indexOf('html[data-platform="darwin"] [data-sidebar-collapsed] [class*="sidebarCol"]')
  assert.notEqual(hiddenSidebar, -1, 'the collapsed sidebar column must be explicitly hidden')
  assert.notEqual(shell.indexOf('min-width: 0 !important;', hiddenSidebar), -1)
  assert.notEqual(shell.indexOf('padding: 0 !important;', hiddenSidebar), -1)
  assert.equal(shell.indexOf('--dsh-shell-sidebar-width'), -1, 'the shell must not force a collapsed rail width')
  assert.equal(shell.indexOf('align-self: center !important;'), -1, 'the shell must not center a hidden rail panel')
})
