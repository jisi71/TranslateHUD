'use strict'

// CloudBase uploads this folder. `npm run stage` copies ../../src to ./src first.
let cloudEntry
try {
  cloudEntry = require('./src/cloudEntry')
} catch {
  cloudEntry = require('../../src/cloudEntry')
}

exports.main = cloudEntry.main
