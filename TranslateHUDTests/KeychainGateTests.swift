import XCTest
@testable import TranslateHUD

final class KeychainGateTests: XCTestCase {
    private func isolate(_ body: (UserDefaults, String, RecordingKeychain) throws -> Void) rethrows {
        let name = "KeychainGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name, RecordingKeychain())
    }

    private func secret(
        defaults: UserDefaults,
        domain: String,
        keychain: RecordingKeychain
    ) -> StoredSecret {
        StoredSecret(
            account: KeychainGate.apiKeyAccount,
            flagKey: KeychainGate.apiKeyFlag,
            defaults: defaults,
            domain: domain,
            keychain: keychain,
            isLegacyKey: KeychainGate.isAppLegacyKey
        )
    }

    func testFreshInstallDoesNotReadOrWriteTheAPIKey() {
        isolate { defaults, domain, keychain in
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(store.value, "")
            XCTAssertFalse(store.hasSecret)
            XCTAssertEqual(store.value, "")
            XCTAssertTrue(keychain.lookups.isEmpty)
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertNotNil(defaults.object(forKey: KeychainGate.apiKeyFlag))
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.apiKeyFlag))

            let again = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(again.value, "")
            XCTAssertTrue(keychain.lookups.isEmpty)
        }
    }

    func testFalseFlagDoesNotReadEvenWhenAnItemExists() {
        isolate { defaults, domain, keychain in
            defaults.set(false, forKey: KeychainGate.apiKeyFlag)
            keychain.items[KeychainGate.apiKeyAccount] = "sk-hidden"
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(store.value, "")
            XCTAssertFalse(store.hasSecret)
            XCTAssertTrue(keychain.lookups.isEmpty)
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-hidden")
        }
    }

    func testKeychainFlagsAreNotTreatedAsAnOldInstall() {
        isolate { defaults, domain, keychain in
            defaults.set(true, forKey: KeychainGate.trialSessionFlag)
            XCTAssertFalse(KeychainGate.hasLegacyInstall(
                defaults: defaults,
                domain: domain,
                isLegacyKey: KeychainGate.isAppLegacyKey
            ))
            XCTAssertEqual(
                KeychainGate.plan(
                    flagKey: KeychainGate.apiKeyFlag,
                    defaults: defaults,
                    domain: domain,
                    isLegacyKey: KeychainGate.isAppLegacyKey
                ),
                .skip
            )
            _ = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertTrue(keychain.lookups.isEmpty)
        }
    }

    func testFalseFlagWinsOverLegacySettings() {
        isolate { defaults, domain, _ in
            defaults.set("https://api.openai.com/v1", forKey: "translation.baseURL")
            defaults.set(false, forKey: KeychainGate.apiKeyFlag)
            XCTAssertEqual(
                KeychainGate.plan(
                    flagKey: KeychainGate.apiKeyFlag,
                    defaults: defaults,
                    domain: domain,
                    isLegacyKey: KeychainGate.isAppLegacyKey
                ),
                .skip
            )
        }
    }

    func testLegacySettingsMigrateAStoredAPIKeyOnceAndKeepItInMemory() {
        isolate { defaults, domain, keychain in
            defaults.set("https://api.openai.com/v1", forKey: "translation.baseURL")
            keychain.items[KeychainGate.apiKeyAccount] = "sk-test\n"
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(store.value, "sk-test")
            XCTAssertTrue(store.hasSecret)
            XCTAssertEqual(store.value, "sk-test")
            XCTAssertEqual(keychain.lookups, [KeychainGate.apiKeyAccount])
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-test\n")
            XCTAssertTrue(defaults.bool(forKey: KeychainGate.apiKeyFlag))

            store.update("sk-test")
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-test\n")

            let nextLaunch = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(nextLaunch.value, "sk-test")
            XCTAssertEqual(keychain.lookups.count, 2)
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-test\n")
        }
    }

    func testLegacySettingsWithoutAnAPIKeyRecordTheFlagAsFalse() {
        isolate { defaults, domain, keychain in
            defaults.set(0.46, forKey: "speech.rate")
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(store.value, "")
            XCTAssertEqual(keychain.lookups, [KeychainGate.apiKeyAccount])
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.apiKeyFlag))

            _ = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(keychain.lookups.count, 1)
        }
    }

    func testMigratingABlankAPIKeyDeletesItOnce() {
        isolate { defaults, domain, keychain in
            defaults.set("gpt-4o-mini", forKey: "translation.model")
            keychain.items[KeychainGate.apiKeyAccount] = "   "
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(store.value, "")
            XCTAssertFalse(store.hasSecret)
            XCTAssertNil(keychain.items[KeychainGate.apiKeyAccount])
            XCTAssertEqual(keychain.deletes, [KeychainGate.apiKeyAccount])
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.apiKeyFlag))

            _ = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(keychain.lookups.count, 1)
            XCTAssertEqual(keychain.deletes.count, 1)
        }
    }

    func testSavedFlagReadsOncePerLaunchWithoutRewritingTheItem() {
        isolate { defaults, domain, keychain in
            defaults.set(true, forKey: KeychainGate.apiKeyFlag)
            keychain.items[KeychainGate.apiKeyAccount] = "sk-kept"
            let first = secret(defaults: defaults, domain: domain, keychain: keychain)
            let second = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(first.value, "sk-kept")
            XCTAssertEqual(second.value, "sk-kept")
            XCTAssertEqual(keychain.lookups.count, 2)
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-kept")
        }
    }

    func testMissingItemClearsTheFlagAndAFailedReadKeepsIt() {
        isolate { defaults, domain, keychain in
            defaults.set(true, forKey: KeychainGate.apiKeyFlag)
            let missing = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(missing.value, "")
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.apiKeyFlag))

            defaults.set(true, forKey: KeychainGate.apiKeyFlag)
            keychain.items[KeychainGate.apiKeyAccount] = "sk-keep"
            keychain.failLookups = true
            let failed = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(failed.value, "")
            XCTAssertTrue(defaults.bool(forKey: KeychainGate.apiKeyFlag))
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-keep")
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertTrue(keychain.sets.isEmpty)
        }
    }

    func testSavingAKeySetsTheFlagWithoutDeleting() {
        isolate { defaults, domain, keychain in
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            store.update("  sk-live  ")
            XCTAssertEqual(store.value, "sk-live")
            XCTAssertTrue(store.hasSecret)
            XCTAssertEqual(keychain.sets, [KeychainGate.apiKeyAccount])
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-live")
            XCTAssertTrue(defaults.bool(forKey: KeychainGate.apiKeyFlag))

            store.update("sk-live")
            XCTAssertEqual(keychain.sets.count, 1)
            XCTAssertTrue(keychain.deletes.isEmpty)
        }
    }

    func testChangingAKeyUpdatesItInPlace() {
        isolate { defaults, domain, keychain in
            defaults.set(true, forKey: KeychainGate.apiKeyFlag)
            keychain.items[KeychainGate.apiKeyAccount] = "sk-old"
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            store.update("sk-new")
            XCTAssertEqual(keychain.deletes, [])
            XCTAssertEqual(keychain.sets, [KeychainGate.apiKeyAccount])
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-new")
            XCTAssertTrue(defaults.bool(forKey: KeychainGate.apiKeyFlag))
        }
    }

    func testClearingTheKeyDeletesTheItemAndClearsTheFlag() {
        isolate { defaults, domain, keychain in
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            store.update("sk-live")
            store.update("   ")
            XCTAssertEqual(store.value, "")
            XCTAssertFalse(store.hasSecret)
            XCTAssertNil(keychain.items[KeychainGate.apiKeyAccount])
            XCTAssertEqual(keychain.deletes, [KeychainGate.apiKeyAccount])
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.apiKeyFlag))

            store.update("")
            XCTAssertEqual(keychain.deletes.count, 1)
            XCTAssertEqual(keychain.sets.count, 1)
        }
    }

    func testClearingWhenNothingWasStoredDoesNotTouchTheKeychain() {
        isolate { defaults, domain, keychain in
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            store.update("")
            store.update("   ")
            XCTAssertTrue(keychain.lookups.isEmpty)
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.apiKeyFlag))
        }
    }

    func testFailedSaveDoesNotMarkTheKeyAsStoredAndCanBeRetried() {
        isolate { defaults, domain, keychain in
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            keychain.failSets = true
            store.update("sk-nope")
            XCTAssertEqual(store.value, "sk-nope")
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.apiKeyFlag))
            XCTAssertNil(keychain.items[KeychainGate.apiKeyAccount])

            keychain.failSets = false
            store.update("sk-nope")
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-nope")
            XCTAssertTrue(defaults.bool(forKey: KeychainGate.apiKeyFlag))
        }
    }

    func testFailedOverwriteKeepsTheExistingFlagAndItem() {
        isolate { defaults, domain, keychain in
            defaults.set(true, forKey: KeychainGate.apiKeyFlag)
            keychain.items[KeychainGate.apiKeyAccount] = "sk-old"
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            keychain.failSets = true
            store.update("sk-new")
            XCTAssertEqual(store.value, "sk-new")
            XCTAssertTrue(defaults.bool(forKey: KeychainGate.apiKeyFlag))
            XCTAssertEqual(keychain.items[KeychainGate.apiKeyAccount], "sk-old")
            XCTAssertTrue(keychain.deletes.isEmpty)
        }
    }

    func testFreshInstallDoesNotReadTheTrialSession() {
        isolate { defaults, domain, keychain in
            let session = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertFalse(session.didRead)
            XCTAssertFalse(session.isLoggedIn)
            XCTAssertTrue(keychain.lookups.isEmpty)
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertNotNil(defaults.object(forKey: KeychainGate.trialSessionFlag))
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.trialSessionFlag))
        }
    }

    func testAPIKeySettingsDoNotCauseATrialKeychainRead() {
        isolate { defaults, domain, keychain in
            defaults.set("https://api.openai.com/v1", forKey: "translation.baseURL")
            defaults.set(true, forKey: "KeyboardShortcuts_triggerSelection")
            let session = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertFalse(session.didRead)
            XCTAssertTrue(keychain.lookups.isEmpty)
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.trialSessionFlag))
        }
    }

    func testTrialLegacyDeviceMigratesASavedSessionWithoutRewritingIt() {
        isolate { defaults, domain, keychain in
            defaults.set("device", forKey: "trial.deviceId")
            keychain.items[TrialKeychain.Account.access] = "access"
            keychain.items[TrialKeychain.Account.refresh] = "refresh"
            keychain.items[TrialKeychain.Account.userId] = "user"
            keychain.items[TrialKeychain.Account.phone] = "138****8000"
            keychain.items[TrialKeychain.Account.expires] = "1700000000"
            let session = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertTrue(session.didRead)
            XCTAssertTrue(session.isLoggedIn)
            XCTAssertEqual(session.accessToken, "access")
            XCTAssertEqual(session.refreshToken, "refresh")
            XCTAssertEqual(session.userId, "user")
            XCTAssertEqual(session.maskedPhone, "138****8000")
            XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertEqual(keychain.lookups, TrialKeychain.Account.all)
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertTrue(defaults.bool(forKey: KeychainGate.trialSessionFlag))

            let nextLaunch = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertTrue(nextLaunch.isLoggedIn)
            XCTAssertEqual(keychain.lookups.count, TrialKeychain.Account.all.count * 2)
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
        }
    }

    func testTrialLegacyWithoutASessionDoesNotStayMarked() {
        isolate { defaults, domain, keychain in
            defaults.set("device", forKey: "trial.deviceId")
            let session = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertTrue(session.didRead)
            XCTAssertFalse(session.isLoggedIn)
            XCTAssertEqual(keychain.lookups.count, TrialKeychain.Account.all.count)
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.trialSessionFlag))

            _ = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(keychain.lookups.count, TrialKeychain.Account.all.count)
        }
    }

    func testLogoutDeletesTrialItemsAndTheNextLaunchDoesNotRead() throws {
        try isolate { defaults, domain, keychain in
            let expires = Date(timeIntervalSince1970: 1_700_000_100)
            try TrialKeychain.write(
                accessToken: "access",
                refreshToken: "refresh",
                userId: "user",
                expiresAt: expires,
                defaults: defaults,
                keychain: keychain
            )
            XCTAssertEqual(keychain.sets, [
                TrialKeychain.Account.access,
                TrialKeychain.Account.refresh,
                TrialKeychain.Account.userId,
                TrialKeychain.Account.expires
            ])
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertTrue(defaults.bool(forKey: KeychainGate.trialSessionFlag))
            XCTAssertEqual(keychain.items[TrialKeychain.Account.access], "access")

            TrialKeychain.clear(defaults: defaults, keychain: keychain)
            XCTAssertEqual(keychain.deletes, TrialKeychain.Account.all)
            XCTAssertTrue(keychain.items.isEmpty)
            XCTAssertFalse(defaults.bool(forKey: KeychainGate.trialSessionFlag))

            let lookups = keychain.lookups.count
            let session = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertFalse(session.isLoggedIn)
            XCTAssertFalse(session.didRead)
            XCTAssertEqual(keychain.lookups.count, lookups)
        }
    }

    func testIncompleteTrialSessionIsNotMarkedSaved() {
        isolate { defaults, _, keychain in
            XCTAssertThrowsError(try TrialKeychain.write(
                accessToken: "",
                refreshToken: "refresh",
                userId: "user",
                expiresAt: Date(),
                defaults: defaults,
                keychain: keychain
            ))
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertNil(defaults.object(forKey: KeychainGate.trialSessionFlag))
        }
    }

    func testFailedTrialReadKeepsTheSavedFlag() {
        isolate { defaults, domain, keychain in
            defaults.set(true, forKey: KeychainGate.trialSessionFlag)
            keychain.items[TrialKeychain.Account.access] = "access"
            keychain.failLookups = true
            let session = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertTrue(session.didRead)
            XCTAssertFalse(session.isLoggedIn)
            XCTAssertTrue(defaults.bool(forKey: KeychainGate.trialSessionFlag))
            XCTAssertEqual(keychain.items[TrialKeychain.Account.access], "access")
            XCTAssertTrue(keychain.deletes.isEmpty)
            XCTAssertTrue(keychain.sets.isEmpty)
        }
    }

    func testPrepareBeforeDefaultShortcutsDoesNotReadTheKeychain() {
        isolate { defaults, domain, keychain in
            KeychainLaunch.prepare(defaults: defaults, domain: domain)
            defaults.set(true, forKey: "KeyboardShortcuts_triggerScreenshot")
            defaults.set(true, forKey: "KeyboardShortcuts_triggerSelection")
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            let session = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(store.value, "")
            XCTAssertFalse(session.didRead)
            XCTAssertTrue(keychain.lookups.isEmpty)
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
        }
    }

    func testShortcutsFromAnOlderLaunchStillRestoreTheAPIKey() {
        isolate { defaults, domain, keychain in
            defaults.set(true, forKey: "KeyboardShortcuts_triggerScreenshot")
            keychain.items[KeychainGate.apiKeyAccount] = "sk-from-before"
            KeychainLaunch.prepare(defaults: defaults, domain: domain)
            XCTAssertNil(defaults.object(forKey: KeychainGate.apiKeyFlag))
            let store = secret(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertEqual(store.value, "sk-from-before")
            XCTAssertEqual(keychain.lookups, [KeychainGate.apiKeyAccount])
            XCTAssertTrue(keychain.sets.isEmpty)
            XCTAssertTrue(keychain.deletes.isEmpty)
            let session = TrialKeychain.restore(defaults: defaults, domain: domain, keychain: keychain)
            XCTAssertFalse(session.didRead)
            XCTAssertEqual(keychain.lookups, [KeychainGate.apiKeyAccount])
        }
    }

    func testNonEmptyKeychainWriteDoesNotStartByDeleting() {
        XCTAssertEqual(KeychainHelper.writeSteps(for: ""), .delete)
        XCTAssertEqual(KeychainHelper.writeSteps(for: "sk-live"), .updateOrCreate)
        XCTAssertNotEqual(KeychainHelper.writeSteps(for: "sk-live"), .delete)
    }
}

private final class RecordingKeychain: KeychainStoring {
    var items: [String: String] = [:]
    private(set) var lookups: [String] = []
    private(set) var sets: [String] = []
    private(set) var deletes: [String] = []
    var failLookups = false
    var failSets = false

    func lookup(_ key: String) -> KeychainLookup {
        lookups.append(key)
        if failLookups { return .unavailable }
        if let value = items[key] { return .found(value) }
        return .missing
    }

    func set(_ value: String, forKey key: String) throws {
        sets.append(key)
        if failSets { throw RecordingKeychainError.failed }
        if value.isEmpty {
            items.removeValue(forKey: key)
            return
        }
        items[key] = value
    }

    func delete(_ key: String) {
        deletes.append(key)
        items.removeValue(forKey: key)
    }
}

private enum RecordingKeychainError: Error {
    case failed
}
