'use strict'

const crypto = require('crypto')
const { MESSAGES, normalizeRecord } = require('./trialPolicy')

const MAX_INFLIGHT = 3
const INFLIGHT_LEASE_MS = 180 * 1000

function activeSlots(record, now) {
  const slots = record && Array.isArray(record.inflight) ? record.inflight : []
  return slots.filter((slot) => slot && Number(slot.until) > now)
}

function emptyBalance(record) {
  if (record && record.giftGranted) {
    return {
      ok: false,
      status: 402,
      code: 'trial_balance_exhausted',
      message: MESSAGES.exhausted
    }
  }
  return {
    ok: false,
    status: 402,
    code: 'trial_invite_required',
    message: MESSAGES.inviteRequired
  }
}

// Holds one slot for this account until release, or until the lease expires
// after a crash. Expired slots do not count, so a dead process cannot stick
// the account at the cap. The balance check is inside the same update so a
// zero balance does not take a slot or start an upstream call.
function acquireSlot(record, now, limit = MAX_INFLIGHT, leaseMs = INFLIGHT_LEASE_MS) {
  const current = record ? normalizeRecord(record) : null
  if (!current) return emptyBalance(null)
  const slots = activeSlots(current, now)
  const pruned = slots.length !== current.inflight.length
  const prunedRecord = pruned ? { ...current, inflight: slots } : current
  if (current.balanceMicroYuan <= 0) {
    return { ...emptyBalance(current), record: prunedRecord }
  }
  if (slots.length >= limit) {
    return {
      ok: false,
      status: 429,
      code: 'trial_concurrency',
      message: MESSAGES.concurrency,
      record: prunedRecord
    }
  }
  const slotId = crypto.randomUUID()
  return {
    ok: true,
    slotId,
    record: {
      ...current,
      inflight: slots.concat([{ id: slotId, until: now + leaseMs }])
    }
  }
}

function releaseSlot(record, slotId) {
  const current = record ? normalizeRecord(record) : null
  if (!current) return null
  return {
    ...current,
    inflight: current.inflight.filter((slot) => slot.id !== slotId)
  }
}

module.exports = {
  MAX_INFLIGHT,
  INFLIGHT_LEASE_MS,
  acquireSlot,
  releaseSlot
}
