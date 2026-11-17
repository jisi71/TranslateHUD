'use strict'

// Same managed-auth identity boundary as the verified trial $LATEST source:
// Bearer -> /auth/v1/user/me -> sub/user_id. No profile, ledger or model access.
async function verifyFeedbackUser({ gateway, token, fetchImpl = fetch }) {
  const response = await fetchImpl(`${gateway}/auth/v1/user/me`, {
    headers: { Authorization: `Bearer ${token}` }, redirect: 'error',
    signal: AbortSignal.timeout(10000)
  })
  if (!response.ok) throw new Error('quality_feedback_auth')
  const body = await response.json()
  const uid = String(body.sub || body.user_id || '').trim()
  if (!uid) throw new Error('quality_feedback_auth')
  return { uid }
}

module.exports = { verifyFeedbackUser }
