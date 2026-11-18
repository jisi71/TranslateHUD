'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { readFileSync } = require('node:fs')
const { createRequire } = require('node:module')
const path = require('node:path')
const { runInNewContext } = require('node:vm')

const root = process.env.TRIAL_CANDIDATE_ROOT
assert.ok(root && path.isAbsolute(root))
const entry = path.join(root, 'server.js')
const load = createRequire(entry)
const sourceTokens = load.resolve('./src/sourceTokens')

for (const version of ['$LATEST', '1']) {
  test(`tokenizer startup for ${version}`, () => {
    delete require.cache[sourceTokens]
    const { countSourceTokens } = load('./src/sourceTokens')
    const logs = []
    const stages = []
    const shouldWarm = version === '1'
    let listened = false
    const http = {
      createServer: () => ({
        listen(port) {
          assert.equal(port, 9000)
          assert.equal(logs.length, shouldWarm ? 1 : 0)
          const tokens = countSourceTokens('Hello world', {
            now: () => 0,
            addQuota: stage => stages.push(stage)
          })
          assert.ok(tokens > 0)
          listened = true
        }
      })
    }
    runInNewContext(readFileSync(entry, 'utf8'), {
      require: name => name === 'http' ? http : load(name),
      process: { env: { SCF_FUNCTIONVERSION: version, PORT: '9000' } },
      console: { log: line => logs.push(JSON.parse(line)) }
    }, { filename: entry })
    assert.equal(listened, true)
    assert.ok(stages.includes('quota_token_encode_ms'))
    assert.equal(stages.includes('quota_tokenizer_init_ms'), !shouldWarm)
    if (shouldWarm) {
      assert.equal(logs[0].event, 'trial_tokenizer_ready')
      assert.equal(logs[0].version, version)
      assert.ok(logs[0].duration_ms > 0)
    }
  })
}
