//
//  ShareSenderTests.swift
//  TetherFrameworkTests
//

import Foundation
import Testing
@testable import TetherFramework

struct ShareSenderTests {
    // The main app reconnects to this endpoint when discovery finds nothing, so a
    // persisted host must come back as the same host and port.
    @Test func lastEndpointRoundTrips() {
        let defaults = CertificateManager.sharedDefaults
        let savedHost = defaults.string(forKey: "TetherLastHost")
        let savedPort = defaults.object(forKey: "TetherLastPort")
        defer {
            defaults.set(savedHost, forKey: "TetherLastHost")
            defaults.set(savedPort, forKey: "TetherLastPort")
        }

        ShareSender.persistLastEndpoint(host: "100.101.102.103", port: 5134)
        let endpoint = ShareSender.lastEndpoint()
        #expect(endpoint?.host == "100.101.102.103")
        #expect(endpoint?.port == 5134)

        ShareSender.persistLastEndpoint(host: "", port: 5134)
        #expect(ShareSender.lastEndpoint() == nil)

        defaults.set("100.101.102.103", forKey: "TetherLastHost")
        defaults.set(99999, forKey: "TetherLastPort")
        #expect(ShareSender.lastEndpoint() == nil)
    }
}
