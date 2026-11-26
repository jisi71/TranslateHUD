'use strict'

const { createHash, randomUUID } = require('node:crypto')

const RETRY_WINDOW_MS = 3 * 60 * 1000
const MAX_RECEIPTS = 64
const REQUEST_ID = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/

function readAttempt(headers, subject) {
  const read = (name) => Object.entries(headers)
    .filter(([key]) => key.toLowerCase() === name)
    .map(([, value]) => value)
  const original = read('x-translatehud-request-id')
  const retry = read('x-translatehud-retry-of')
  if (original.length + retry.length === 0) return null
  const id = original[0] ?? retry[0]
  if (original.length + retry.length !== 1 || typeof id !== 'string' || !REQUEST_ID.test(id) || !subject) {
    return { invalid: true }
  }
  return {
    id,
    retry: retry.length === 1,
    digest: createHash('sha256').update(JSON.stringify(subject)).digest('hex')
  }
}

function normalizeReceipts(records) {
  return Array.isArray(records) ? records.filter(row =>
    row && typeof row.id === 'string' && REQUEST_ID.test(row.id)
    && typeof row.digest === 'string' && /^[a-f0-9]{64}$/.test(row.digest)
    && Number.isSafeInteger(row.settledAt) && typeof row.used === 'boolean'
  ).slice(-MAX_RECEIPTS) : []
}

function recentReceipts(record, now) {
  return normalizeReceipts(record?.retryReceipts)
    .filter(row => row.settledAt <= now && now - row.settledAt < RETRY_WINDOW_MS)
}

function reserveRetry(record, attempt, now, maxInflight, leaseMs, concurrencyMessage) {
  const receipts = recentReceipts(record, now)
  const original = receipts.find(row => row.id === attempt.id)
  if (!original || original.used || original.digest !== attempt.digest) {
    return { ok: false, status: 409, code: 'trial_retry_unavailable', message: '本次自动重试凭证已失效。' }
  }
  const slots = record.inflight.filter(slot => slot.until > now)
  if (slots.length >= maxInflight) {
    return { ok: false, status: 429, code: 'trial_concurrency', message: concurrencyMessage }
  }
  const slotId = randomUUID()
  return {
    ok: true,
    slotId,
    record: {
      ...record,
      retryReceipts: receipts.map(row => row.id === original.id ? { ...row, used: true } : row),
      inflight: slots.concat({ id: slotId, until: now + leaseMs })
    }
  }
}

function finishAttempt(settled, attempt, now, actualCost, displayFen) {
  if (!attempt || !settled.record) return settled
  if (attempt.retry) {
    return { ...settled, costMicroYuan: actualCost, costFen: displayFen(actualCost), retryWaived: true }
  }
  const retryReceipts = recentReceipts(settled.record, now)
  // Settling a duplicate paid request must not renew or restore a waiver.
  if (retryReceipts.some(row => row.id === attempt.id)) return settled
  retryReceipts.push({ id: attempt.id, digest: attempt.digest, settledAt: now, used: false })
  return { ...settled, retryRequestId: attempt.id,
    record: { ...settled.record, retryReceipts: retryReceipts.slice(-MAX_RECEIPTS) } }
}

module.exports = { readAttempt, normalizeReceipts, reserveRetry, finishAttempt, RETRY_WINDOW_MS }
