import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const MAIN_WINDOW_SOURCE = fs.readFileSync(
  new URL('../Sources/MainWindow/MainWindowController.swift', import.meta.url),
  'utf8',
)

test('Swift shell converts local attachment navigations into WKDownloads', () => {
  assert.match(MAIN_WINDOW_SOURCE, /WKDownloadDelegate/)
  assert.match(MAIN_WINDOW_SOURCE, /navigationAction\.shouldPerformDownload/)
  assert.match(MAIN_WINDOW_SOURCE, /contentDisposition\?\.contains\("attachment"\)/)
  assert.match(MAIN_WINDOW_SOURCE, /!navigationResponse\.canShowMIMEType/)
  assert.match(MAIN_WINDOW_SOURCE, /decisionHandler\(\.download\)/)
  assert.equal((MAIN_WINDOW_SOURCE.match(/download\.delegate = self/g) ?? []).length, 2)
})

test('Swift shell accepts only active-Runtime Blob downloads from its main frame', () => {
  assert.match(MAIN_WINDOW_SOURCE, /private func isCurrentRuntimeBlobURL\(_ url: URL, sourceFrame: WKFrameInfo\) -> Bool/)
  assert.match(MAIN_WINDOW_SOURCE, /url\.scheme\?\.caseInsensitiveCompare\("blob"\)/)
  assert.match(MAIN_WINDOW_SOURCE, /sourceFrame\.isMainFrame/)
  assert.match(MAIN_WINDOW_SOURCE, /isCurrentRuntimeWebOrigin\(sourceFrame\.securityOrigin\)/)
  assert.match(MAIN_WINDOW_SOURCE, /URL\(string: String\(url\.absoluteString\.dropFirst\(blobPrefix\.count\)\)\)/)
  assert.match(MAIN_WINDOW_SOURCE, /navigationAction\.shouldPerformDownload && \(isRuntimeURL \|\| isRuntimeBlobURL\)/)
  assert.match(MAIN_WINDOW_SOURCE, /else if isRuntimeURL \|\| isRuntimeBlobURL\s*\{\s*decisionHandler\(\.allow\)/)
  assert.match(MAIN_WINDOW_SOURCE, /else if url\.scheme\?\.caseInsensitiveCompare\("blob"\) == \.orderedSame\s*\{\s*\/\/ Never ask LaunchServices to open an opaque WebKit object URL\.\s*decisionHandler\(\.cancel\)/)
})

test('Swift downloads open a native save panel with Downloads as the default location', () => {
  assert.match(MAIN_WINDOW_SOURCE, /urls\(for: \.downloadsDirectory, in: \.userDomainMask\)/)
  assert.match(MAIN_WINDOW_SOURCE, /let panel = NSSavePanel\(\)/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.directoryURL = defaults\.directory/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.nameFieldStringValue = defaults\.filename/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.title = "保存下载"/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.message = "选择下载文件的保存位置。"/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.beginSheetModal\(for: window\)/)
  assert.match(MAIN_WINDOW_SOURCE, /guard response == \.OK, let destination = panel\.url/)
  assert.match(MAIN_WINDOW_SOURCE, /downloadDestinations\[ObjectIdentifier\(download\)\]/)
})

test('Swift WebKit file inputs open a native panel and return selected URLs', () => {
  assert.match(MAIN_WINDOW_SOURCE, /WKUIDelegate/)
  assert.match(MAIN_WINDOW_SOURCE, /runOpenPanelWith parameters: WKOpenPanelParameters/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.canChooseFiles = true/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.canChooseDirectories = parameters\.allowsDirectories/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.allowsMultipleSelection = parameters\.allowsMultipleSelection/)
  assert.match(MAIN_WINDOW_SOURCE, /let parentWindow = webView\.window \?\? window/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.beginSheetModal\(for: parentWindow, completionHandler: finish\)/)
  assert.match(MAIN_WINDOW_SOURCE, /panel\.begin\(completionHandler: finish\)/)
  assert.match(MAIN_WINDOW_SOURCE, /completionHandler\(panel\.urls\)/)
  assert.match(MAIN_WINDOW_SOURCE, /completionHandler\(nil\)/)
})

test('Swift downloads show their destination and reveal completed files in Finder', () => {
  assert.match(MAIN_WINDOW_SOURCE, /statusLabel\.stringValue = completed \? "下载完成" : "正在下载"/)
  assert.match(MAIN_WINDOW_SOURCE, /pathLabel\.stringValue =/)
  assert.match(MAIN_WINDOW_SOURCE, /showDownloadStatus\(destination: destination, completed: false\)/)
  assert.match(MAIN_WINDOW_SOURCE, /showDownloadStatus\(destination: destination, completed: true\)/)
  assert.match(MAIN_WINDOW_SOURCE, /activateFileViewerSelecting\(\[destination\]\)/)
})

test('Swift ignores only expected navigation cancellation and download policy changes', () => {
  assert.match(MAIN_WINDOW_SOURCE, /NSURLErrorCancelled/)
  assert.match(MAIN_WINDOW_SOURCE, /error\.domain == "WebKitErrorDomain" && error\.code == 102/)
  assert.equal((MAIN_WINDOW_SOURCE.match(/isExpectedNavigationInterruption\(error\)/g) ?? []).length, 3)
})
