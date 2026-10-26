'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..', '..')

function read(relative) {
  return fs.readFileSync(path.join(root, relative), 'utf8')
}

const pages = [
  'TranslateHUD/Resources/Legal/user-agreement.md',
  'TranslateHUD/Resources/Legal/privacy-policy.md'
]

const screens = [
  'TranslateHUD/Settings/SettingsView.swift',
  'TranslateHUD/Settings/HelpView.swift',
  'TranslateHUD/Settings/FeedbackView.swift',
  'TranslateHUD/Settings/LegalDocumentView.swift',
  'TranslateHUD/Trial/FeedbackClient.swift'
]

test('help pages do not link to a website or an email address', () => {
  for (const relative of [...pages, ...screens]) {
    const text = read(relative)
    assert.equal(text.toLowerCase().includes('mailto:'), false, relative)
    assert.equal(text.includes('http://'), false, relative)
    assert.equal(text.includes('https://'), false, relative)
  }
  for (const relative of screens) {
    assert.equal(read(relative).includes('邮箱'), false, relative)
  }
  const agreement = read(pages[0])
  const privacy = read(pages[1])
  for (const text of [agreement, privacy]) {
    assert.equal(text.includes('【'), false)
    assert.equal(text.includes('】'), false)
    assert.equal(text.includes('统一社会信用代码'), false)
    assert.equal(text.includes('草案'), false)
    assert.equal(text.includes('如实际收集请保留'), false)
    assert.equal(text.includes('齐亚浩（个人）'), true)
    assert.equal(text.includes('translatehud@agent.qq.com'), true)
    assert.equal(text.includes('2026-10-26'), true)
    assert.equal(text.includes('可通过上述邮箱索取'), true)
  }
  assert.equal(agreement.includes('运营者住所地（北京市）'), true)
  assert.match(privacy, /隐私政策/)
  assert.match(privacy, /腾讯云开发/)
  assert.match(privacy, /意见反馈/)
  assert.match(privacy, /6\. 设备与日志\n/)
  const help = read('TranslateHUD/Settings/HelpView.swift')
  assert.match(help, /问题反馈/)
  assert.match(help, /用户协议/)
  assert.match(help, /隐私政策/)
  const settings = read('TranslateHUD/Settings/SettingsView.swift')
  assert.match(settings, /帮助/)
  assert.match(settings, /登录即表示已阅读/)
  const note = read('TranslateHUD/Resources/Legal/README.md')
  assert.match(note, /法务/)
  assert.match(note, /user-agreement\.md/)
  assert.match(note, /privacy-policy\.md/)
})
