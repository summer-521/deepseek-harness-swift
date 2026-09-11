import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'

const testDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryDirectory = path.join(testDirectory, '..')
const clientSource = fs.readFileSync(
  path.join(repositoryDirectory, 'assets', 'dsh-desktop-host', 'client.js'),
  'utf8',
)

function observable(initial) {
  let value = initial
  const listeners = new Set()
  return {
    getSnapshot: () => value,
    subscribe(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    set(next) {
      value = next
      for (const listener of [...listeners]) listener()
    },
    listenerCount: () => listeners.size,
  }
}

function fakeDocument() {
  const element = () => ({
    style: {},
    setAttribute() {},
    appendChild() {},
    remove() {},
  })
  return {
    body: { textContent: 'x'.repeat(200) },
    documentElement: { setAttribute() {}, removeAttribute() {} },
    head: { appendChild() {} },
    createElement: element,
    querySelector: () => ({}),
    querySelectorAll: () => [],
  }
}

/// Load the desktop-host client plugin the way the DSH web app does: the file
/// registers a module factory on `window.__ModuleLoader__`, and `apply(ctx)`
/// installs the bridge subscriptions.
function loadPlugin({ pending, sessions, withUiSession = true, notify, debug, deferredUiSession = false }) {
  let definition = null
  const host = {
    ready: () => {},
    notify,
    debug: debug ?? (() => {}),
    theme: () => {},
    locale: () => {},
  }
  const sandbox = {
    window: {
      __ModuleLoader__: { load: (value) => { definition = value } },
      dshDesktop: host,
      setTimeout: (fn) => { fn(); return 0 },
      clearTimeout: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      location: { href: 'http://127.0.0.1:3080/' },
    },
    document: fakeDocument(),
    console,
  }
  sandbox.window.window = sandbox.window
  vm.createContext(sandbox)
  vm.runInContext(clientSource, sandbox, { filename: 'client.js' })

  const sessionsStore = observable({ byId: {} })
  const sessionList = sessions ?? sessionsStore
  const pendingStore = pending ?? observable(new Map())
  const injected = []
  const provided = { uiSession: { pendingInteractions: pendingStore } }
  const ctx = {
    locale: undefined,
    theme: undefined,
    on: () => () => {},
    sessions: { list: sessionList },
    uiSession: withUiSession && !deferredUiSession ? provided.uiSession : undefined,
    // `ctx.get` is an immediate read of an *active* service: when the service
    // is not there yet it returns undefined, exactly like Cordis does.
    get: (name) => (withUiSession && !deferredUiSession && name === 'uiSession'
      ? provided.uiSession
      : undefined),
    // `ctx.inject([name], cb)` starts the callback once the service exists.
    inject: (names, callback) => {
      const record = { names, callback, provide: () => {} }
      injected.push(record)
      if (withUiSession && deferredUiSession) {
        record.provide = () => callback(provided)
      }
      return { provide: record.provide }
    },
  }
  const dispose = definition.factory(() => ({})).apply(ctx)
  return { dispose, pendingStore, sessionList, sessionsStore, injected, provided }
}

let interactionSerial = 0
function interaction(sessionId, kind, extra = {}) {
  interactionSerial += 1
  return { sessionId, kind, key: `${kind}:${interactionSerial}`, ...extra }
}

function pendingMap(...entries) {
  // Accept both `pendingMap(['s1', x])` and `pendingMap([['s1', x], ['s2', y]])`
  // so a stray extra array level cannot silently build a map with tuple keys.
  const list = entries.length === 1 && Array.isArray(entries[0]) && Array.isArray(entries[0][0])
    ? entries[0]
    : entries
  const map = new Map()
  for (const [sessionId, value] of list) map.set(sessionId, value)
  return map
}

test('a pending approval or question notifies the shell while the turn stays open', () => {
  const notifications = []
  const { pendingStore, sessionsStore } = loadPlugin({ notify: (payload) => notifications.push(payload) })

  sessionsStore.set({ byId: { s1: { displayTitle: '修复通知', cwd: '/Users/x/project', running: true } } })
  assert.equal(notifications.length, 0, 'a running session alone must not notify')

  // An approval prompt appears: the session keeps running, so the
  // running→idle edge never fires — this is the state that used to hang
  // silently in a hidden window.
  pendingStore.set(pendingMap(['s1', interaction('s1', 'approval', { toolName: 'bash', reason: '需要执行 sudo 命令' })]))
  assert.equal(notifications.length, 1, 'an approval must notify exactly once')
  assert.equal(notifications[0].kind, 'needs-approval', 'an approval has its own notification kind')
  assert.equal(notifications[0].sessionId, 's1')
  assert.equal(notifications[0].reason, '需要执行 sudo 命令')
  assert.equal(notifications[0].title, '修复通知')
  assert.equal(notifications[0].cwd, '/Users/x/project')

  // Repeated snapshots of the same interaction must not notify again, and a
  // remount (same domain, new render key) is still the same pending request.
  const approval = interaction('s1', 'approval', { toolName: 'bash', reason: '需要执行 sudo 命令' })
  pendingStore.set(pendingMap(['s1', approval]))
  pendingStore.set(pendingMap(['s1', approval]))
  pendingStore.set(pendingMap(['s1', interaction('s1', 'approval', { toolName: 'bash', reason: '需要执行 sudo 命令' })]))
  assert.equal(notifications.length, 1, 'an unchanged pending interaction must not notify repeatedly')

  // A question in another session notifies with the question text.
  sessionsStore.set({ byId: {
    s1: { displayTitle: '修复通知', cwd: '/Users/x/project', running: true },
    s2: { displayTitle: '调研', cwd: '/Users/x/other', running: true },
  } })
  pendingStore.set(pendingMap(
    ['s1', interaction('s1', 'approval', { toolName: 'bash', reason: '需要执行 sudo 命令' })],
    ['s2', interaction('s2', 'question', { questions: [{ id: 'q1', question: '要发布 1.2.4 吗？' }] })],
  ))
  assert.equal(notifications.length, 2, 'a second session prompt must notify')
  assert.equal(notifications[1].kind, 'needs-input', 'a question keeps the generic kind')
  assert.equal(notifications[1].reason, '要发布 1.2.4 吗？')
  assert.equal(notifications[1].title, '调研')

  // Answering clears the entry; the next prompt in that session notifies again
  // even when it belongs to the same domain as the previous one.
  const s2Question = interaction('s2', 'question', { questions: [{ id: 'q1', question: '要发布 1.2.4 吗？' }] })
  pendingStore.set(pendingMap(['s2', s2Question]))
  assert.equal(notifications.length, 2, 'answering one session must not re-notify the other')
  pendingStore.set(pendingMap(['s1', interaction('s1', 'question', { questions: [{ id: 'q2', question: '继续吗？' }] })]))
  assert.equal(notifications.length, 3, 'a new prompt after an answer must notify again')
  assert.equal(notifications[2].reason, '继续吗？')
  assert.equal(notifications[2].title, '修复通知', 'the second session summary still resolves')
  pendingStore.set(pendingMap())
  pendingStore.set(pendingMap(['s1', interaction('s1', 'question', { questions: [{ id: 'q3', question: '还有别的吗？' }] })]))
  assert.equal(notifications.length, 4, 'the same domain must notify again once the previous prompt is answered')
  assert.equal(notifications[3].reason, '还有别的吗？')
})

test('a prompt that is already pending when the bridge loads is reported once', () => {
  const notifications = []
  const pendingStore = observable(pendingMap([
    ['s1', interaction('s1', 'approval', { toolName: 'write', reason: '覆盖文件需要确认' })],
  ]))
  loadPlugin({ notify: (payload) => notifications.push(payload), pending: pendingStore })
  assert.equal(notifications.length, 1, 'the initial snapshot must be reported')
  assert.equal(notifications[0].kind, 'needs-approval')
  pendingStore.set(pendingMap([
    ['s1', interaction('s1', 'approval', { toolName: 'write', reason: '覆盖文件需要确认' })],
  ]))
  assert.equal(notifications.length, 1, 'the initial snapshot must not be reported twice')
})

test('a uiSession that appears after apply is picked up through ctx.inject', () => {
  const notifications = []
  const {
    pendingStore,
    sessionsStore,
    injected,
    provided,
  } = loadPlugin({
    notify: (payload) => notifications.push(payload),
    deferredUiSession: true,
  })

  sessionsStore.set({ byId: { s1: { displayTitle: '迟到场景', cwd: '/tmp/late', running: true } } })
  assert.equal(injected.length, 1, 'the plugin must wait for uiSession instead of giving up')
  assert.equal(Array.from(injected[0].names).join(','), 'uiSession')
  assert.equal(notifications.length, 0, 'nothing is pending yet')

  // The Session UI bundle provides the service after our plugin applied.
  injected[0].provide()
  pendingStore.set(pendingMap(['s1', interaction('s1', 'question', { questions: [{ id: 'q1', question: '现在收到了吗？' }] })]))
  assert.equal(notifications.length, 1, 'a late uiSession must still deliver needs-input')
  assert.equal(notifications[0].kind, 'needs-input')
  assert.equal(notifications[0].kind, 'needs-input', 'a question reports needs-input')
  assert.equal(notifications[0].reason, '现在收到了吗？')
  assert.equal(notifications[0].title, '迟到场景')
})

test('a plan review gets its own kind and names the plan in the body', () => {
  const notifications = []
  const { pendingStore, sessionsStore } = loadPlugin({ notify: (payload) => notifications.push(payload) })
  sessionsStore.set({ byId: { s1: { displayTitle: '设计会话', cwd: '/tmp/plan', running: true } } })

  // The plan-mode `exit_plan_mode` tool asks one question whose `detail` is the
  // whole plan and whose `intent.kind` is "plan-review".
  pendingStore.set(pendingMap(['s1', interaction('s1', 'plan-review', {
    questions: [{
      id: 'plan-review',
      header: 'Plan review',
      question: 'Approve this plan and leave plan mode?',
      detail: '# 通知去重方案\n\n1. ...\n2. ...',
      options: [{ label: 'Approve' }, { label: 'Keep planning' }],
      intent: { kind: 'plan-review', approve: 'Approve' },
    }],
  })]))
  assert.equal(notifications.length, 1, 'a plan review must notify')
  assert.equal(notifications[0].kind, 'needs-review', 'a plan review has its own notification kind')
  assert.equal(
    notifications[0].reason,
    '通知去重方案',
    'the body names the plan by its first markdown heading, not the generic review question',
  )

  // A plan review without a heading falls back to the question text.
  pendingStore.set(pendingMap())
  pendingStore.set(pendingMap(['s1', interaction('s1', 'plan-review', {
    questions: [{ id: 'plan-review', question: 'Approve this plan?', detail: 'no heading here' }],
  })]))
  assert.equal(notifications.length, 2, 'a second plan review must notify again')
  assert.equal(notifications[1].reason, 'Approve this plan?')
})

test('the completion notification path is unchanged and survives a missing uiSession', () => {
  const notifications = []
  const { sessionsStore, pendingStore } = loadPlugin({
    notify: (payload) => notifications.push(payload),
    withUiSession: false,
  })
  sessionsStore.set({ byId: { s1: { displayTitle: '任务', cwd: '/tmp/w', running: true } } })
  sessionsStore.set({ byId: { s1: { displayTitle: '任务', cwd: '/tmp/w', running: false } } })
  assert.equal(notifications.length, 1, 'running→idle must still notify completion')
  assert.equal(notifications[0].kind, undefined, 'the completion payload has no kind')
  // Without the uiSession service there is nothing to subscribe to, and the
  // plugin must stay silent instead of throwing.
  pendingStore.set(pendingMap(['s1', interaction('s1', 'approval')]))
  assert.equal(notifications.length, 1, 'a missing uiSession must not produce needs-input notifications')
})

test('the bridge prefers the immediate read and does not double-subscribe', () => {
  const notifications = []
  const { pendingStore, injected } = loadPlugin({ notify: (payload) => notifications.push(payload) })
  assert.equal(injected.length, 0, 'an already-provided uiSession needs no injection')
  pendingStore.set(pendingMap(['s1', interaction('s1', 'approval', { toolName: 'bash' })]))
  assert.equal(notifications.length, 1, 'the fast path attaches exactly once')
})

test('disposing the bridge removes the pending-interaction subscription', () => {
  const notifications = []
  const { dispose, pendingStore } = loadPlugin({ notify: (payload) => notifications.push(payload) })
  dispose()
  pendingStore.set(pendingMap(['s1', interaction('s1', 'approval', { toolName: 'bash' })]))
  assert.equal(notifications.length, 0, 'a disposed bridge must not notify')
})

test('the notify payload contract and routing cover the needs-input extension', () => {
  const validatorSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Bridge', 'DshBridgeMessageValidator.swift'),
    'utf8',
  )
  const handlerSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Bridge', 'DshBridgeHandler.swift'),
    'utf8',
  )
  assert.match(validatorSource, /"title", "cwd", "sessionId", "completedAt", "kind", "reason"/)
  assert.match(validatorSource, /value == "needs-input"[\s\S]{0,120}value == "needs-approval"[\s\S]{0,120}value == "needs-review"/)
  assert.match(
    handlerSource,
    /switch payload\?\["kind"\] as\? String \{[\s\S]{0,600}showNeedsApprovalNotification[\s\S]{0,200}showNeedsReviewNotification[\s\S]{0,200}showNeedsInputNotification[\s\S]{0,200}showTaskDoneNotification/
  )
})

test('approval and question notifications use their own titles', () => {
  const managerSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Notification', 'NotificationManager.swift'),
    'utf8',
  )
  const handlerSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Bridge', 'DshBridgeHandler.swift'),
    'utf8',
  )
  const validatorSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Bridge', 'DshBridgeMessageValidator.swift'),
    'utf8',
  )
  assert.match(managerSource, /deliver\(title: "需要你的输入", body: promptBody\(title: title, reason: reason\)\)/)
  assert.match(managerSource, /deliver\(title: "需要你的批准", body: promptBody\(title: title, reason: reason\)\)/)
  assert.match(managerSource, /deliver\(title: "需要你的确认", body: promptBody\(title: title, reason: reason\)\)/)
  assert.match(handlerSource, /case "needs-approval":[\s\S]{0,120}showNeedsApprovalNotification/)
  assert.match(handlerSource, /case "needs-review":[\s\S]{0,120}showNeedsReviewNotification/)
  assert.match(handlerSource, /case "needs-input":[\s\S]{0,120}showNeedsInputNotification/)
  assert.match(validatorSource, /value == "needs-input"/)
  assert.match(validatorSource, /value == "needs-approval"/)
  assert.match(validatorSource, /value == "needs-review"/)
})

test('the needs-input notification body is the prompt itself', () => {
  const managerSource = fs.readFileSync(
    path.join(repositoryDirectory, 'Sources', 'Notification', 'NotificationManager.swift'),
    'utf8',
  )
  const needsInput = managerSource.slice(
    managerSource.indexOf('public func showNeedsInputNotification'),
    managerSource.indexOf('private func sessionLabel(from title: String?)'),
  )
  assert.match(needsInput, /deliver\(title: "需要你的输入", body: promptBody\(title: title, reason: reason\)\)/)
  assert.doesNotMatch(
    needsInput,
    /工作区/,
    'the prompt notification must not add the workspace line',
  )
  const promptBody = managerSource.slice(
    managerSource.indexOf('private func promptBody'),
    managerSource.indexOf('private func deliver'),
  )
  assert.match(
    promptBody,
    /detail\?\.isEmpty == false[\s\S]{0,140}sessionLabel\(from: title\)/,
    'a prompt without text falls back to the session name',
  )
  const doneBody = managerSource.slice(
    managerSource.indexOf('public func showTaskDoneNotification'),
    managerSource.indexOf('public func showNeedsInputNotification'),
  )
  assert.match(doneBody, /工作区：/, 'the completion notification keeps its workspace line')
})
