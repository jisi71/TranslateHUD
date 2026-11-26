'use strict'

// CloudBase uses its own verified source bundle. See backend/deployment-tests/README.md.
let cloudEntry
try {
  cloudEntry = require('./src/cloudEntry')
} catch {
  cloudEntry = require('../../src/cloudEntry')
}

exports.main = cloudEntry.main
