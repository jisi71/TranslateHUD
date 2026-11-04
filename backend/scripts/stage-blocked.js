'use strict'

// The checked-in shared backend is older than the two deployed functions.
// Copying it into trial would silently remove the deployed daily quota.
console.error('已阻止从旧 backend/src 打包 trial：线上源码包含每日免费额度且与仓库不同。')
console.error('请先核对线上代码包及 backend/deployment-tests/README.md，不能用此脚本覆盖线上。')
process.exitCode = 1
