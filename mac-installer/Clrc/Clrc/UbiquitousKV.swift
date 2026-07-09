//
//  UbiquitousKV.swift
//  Clrc
//
//  KVStore adapter over NSUbiquitousKeyValueStore for optional iCloud hub sync.
//  Stateless (no stored reference) so it stays trivially Sendable.
//

import Foundation
import ClrcInstallerCore

struct UbiquitousKV: KVStore {
    func data(forKey key: String) -> Data? {
        NSUbiquitousKeyValueStore.default.data(forKey: key)
    }
    func set(_ data: Data?, forKey key: String) {
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}
