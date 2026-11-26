'use strict'

const { createHash } = require('node:crypto')

const MAX_TTL_MS = 60 * 60 * 1000
const DEFAULT_TTL_MS = 5 * 60 * 1000
const EXPIRY_MARGIN_MS = 30 * 1000
const MAX_ENTRIES = 2000
const cache = new Map()
const verifierIds = new WeakMap()
let nextVerifierId = 0

function ttlFrom(value) {
  if (value == null || value === '') return DEFAULT_TTL_MS
  const ttl = Number(value)
  return Number.isFinite(ttl) ? Math.max(0, Math.min(ttl, MAX_TTL_MS)) : DEFAULT_TTL_MS
}

function jwtExpiry(token) {
  const parts = token.split('.')
  if (parts.length !== 3 || !/^[A-Za-z0-9_-]+$/.test(parts[1])) return null
  try {
    const { exp } = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'))
    return Number.isFinite(exp) && Number.isFinite(exp * 1000) ? exp * 1000 : null
  } catch {
    return null
  }
}

async function verifyTranslationUser({ gateway, token, verifyUser, ttlValue, now }) {
  const ttl = ttlFrom(ttlValue)
  if (!ttl) return verifyUser({ gateway, token })
  if (!verifierIds.has(verifyUser)) verifierIds.set(verifyUser, ++nextVerifierId)
  const digest = createHash('sha256').update(token).digest('hex')
  const key = JSON.stringify([verifierIds.get(verifyUser), gateway, digest])
  const current = now()
  const expiry = jwtExpiry(token)
  const bound = expiry === null ? current + Math.min(ttl, DEFAULT_TTL_MS) : expiry - EXPIRY_MARGIN_MS
  const entry = cache.get(key)
  if (entry) {
    cache.delete(key)
    if (current >= entry.verifiedAt && current < Math.min(entry.expiresAt, entry.verifiedAt + ttl, bound)) {
      cache.set(key, entry)
      return entry.user
    }
  }

  // Only a successful response from CloudBase establishes identity. JWT claims cap its lifetime.
  const user = await verifyUser({ gateway, token })
  const verifiedAt = now()
  const expiresAt = Math.min(verifiedAt + ttl, expiry === null ? verifiedAt + DEFAULT_TTL_MS : bound)
  if (user?.uid && expiresAt > verifiedAt) {
    cache.set(key, {
      verifiedAt, expiresAt,
      user: { uid: String(user.uid) }
    })
    if (cache.size > MAX_ENTRIES) cache.delete(cache.keys().next().value)
  }
  return user
}

module.exports = { verifyTranslationUser }
