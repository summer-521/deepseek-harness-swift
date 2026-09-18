import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const shell = fs.readFileSync(new URL('../Sources/MainWindow/DshWebShell.swift', import.meta.url), 'utf8')

test('Runtime Plugins panel keeps its Runtime position and centers when collapsed', () => {
  const pluginPanel = shell.indexOf('[class*="panelList"]:has([aria-label="插件"], [aria-label="Plugins"])')
  assert.notEqual(pluginPanel, -1, 'the injected CSS must identify the Runtime Plugins panel')

  const collapsedLayout = shell.indexOf('[class*="root"][class*="collapsed"] [class*="panelList"]:has([aria-label="插件"], [aria-label="Plugins"])')
  const centeredRow = shell.indexOf('align-self: center !important;', collapsedLayout)

  assert.notEqual(collapsedLayout, -1, 'the collapsed Plugins panel must have a dedicated layout override')
  assert.notEqual(centeredRow, -1, 'the collapsed Plugins row must be centered in the rail')
  assert.equal(shell.indexOf('order: 2 !important;', pluginPanel), -1, 'the Plugins panel must keep the Runtime order')
  assert.equal(shell.indexOf('align-self: stretch !important;', pluginPanel), -1, 'the expanded Plugins row must keep the Runtime layout')
  assert.equal(shell.indexOf('padding-left: 6px !important;', pluginPanel), -1, 'the expanded Plugins row must keep the Runtime padding')
})
