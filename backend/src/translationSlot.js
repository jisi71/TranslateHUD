'use strict'

function holdTranslationSlot(release) {
  let settling
  let releasing
  return {
    settle(work) {
      if (releasing) return null
      settling ??= work()
      return settling
    },
    release() {
      releasing ??= (async () => {
        if (settling && await settling.catch(() => null)) return
        try {
          await release()
        } catch (error) {
          console.error(`trial release failed code=${(error && (error.causeCode || error.code)) || 'unknown'}`)
        }
      })()
      return releasing
    }
  }
}

module.exports = { holdTranslationSlot }
