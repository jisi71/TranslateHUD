'use strict'

const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')

const baselines = {
  trial: {
    zip: '2bb77996abe62e71d8690c388592bfecedbb6dece753f162af76c072a382fb11',
    'src/trialMessages.js': 'cd5f9ca6fd3f8fc5facb26cd89b196e33086caabe24cd2b963579e7fc057b783',
    'src/upstream.js': '10b9aab3cac07e2d769f817313fee979937cd60a96ba08a23ed18176ee22a65f',
    'src/trialService.js': '9ecc975d08eff4ed9a4887b8d90464aac168a69d1110a632aabf0774eabc9f08'
  },
  'trial-stream': {
    zip: 'e01e25f377fb40065a9f9e8dd7eca5b93fbcf0143fe53d24b65f1513dc405353',
    'src/trialMessages.js': 'e5f9633f92ddaa120e066124dfc70ba723d5319bdf5a1399a28d88b4575feb7d',
    'src/upstream.js': '10b9aab3cac07e2d769f817313fee979937cd60a96ba08a23ed18176ee22a65f',
    'src/trialService.js': '7eb866a2ad82d70b5428bf9fb46917a5e85d96f30a8bfa98ef2730084e400401'
  }
}

const [kind, archive, root] = process.argv.slice(2)
const expected = baselines[kind]
if (!expected || !archive || !root || !path.isAbsolute(archive) || !path.isAbsolute(root)) {
  throw new Error('usage: node verify-baseline.cjs trial|trial-stream /absolute/package.zip /absolute/extracted-dir')
}
function sha(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') }
if (sha(archive) !== expected.zip) throw new Error('archive SHA-256 mismatch')
for (const [file, digest] of Object.entries(expected)) {
  if (file === 'zip') continue
  if (sha(path.join(root, file)) !== digest) throw new Error(`baseline SHA-256 mismatch: ${file}`)
}
if (fs.existsSync(path.join(root, 'src/structuredBold.js'))) throw new Error('candidate is already patched')
const inputs = {
  'node_modules/@huggingface/tokenizers/package.json': 'f6b9849b58de625c4fd79583242dd4506914b92082f9af17719d39416658ef24',
  'node_modules/@huggingface/tokenizers/dist/tokenizers.cjs': 'fab81302e9d4ebf2c7aec310e35af0df81c28cb1ef7a4ac44ac83848e39ae79c',
  'src/tokenizers/deepseek-v4/tokenizer.json': '97d2f31b020d18b5aee5c9b3d5b4efb10ea210f3fe3f7dffe3f1cd90542d6b19'
}
for (const [file, digest] of Object.entries(inputs)) {
  if (sha(path.join(root, file)) !== digest) throw new Error(`tokenizer SHA-256 mismatch: ${file}`)
}
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'node_modules/@huggingface/tokenizers/package.json'), 'utf8'))
if (pkg.version !== '0.2.0') throw new Error('tokenizer dependency must be 0.2.0')
console.log(`${kind}: archive, source files and tokenizer version match the recorded baseline`)
