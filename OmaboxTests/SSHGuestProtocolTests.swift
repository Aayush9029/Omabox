import CustomDump
import Foundation
import Testing
@testable import Omabox

struct SSHGuestProtocolTests {
    @Test func disablingAndStatusRequestsNeverCarryAPublicKey() throws {
        let disable = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SSHGuestRequest.disable)) as? [String: Any]
        let status = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SSHGuestRequest.status)) as? [String: Any]
        expectNoDifference(disable?["type"] as? String, "configureSSH")
        expectNoDifference(disable?["enabled"] as? Bool, false)
        expectNoDifference(disable?["version"] as? Int, 1)
        #expect(disable?["publicKey"] == nil)
        expectNoDifference(status?["type"] as? String, "sshStatus")
        #expect(status?["publicKey"] == nil)
        #expect(status?["enabled"] == nil)
    }

    @Test(arguments: [
        "{\"type\":\"sshConfigured\",\"version\":2,\"enabled\":false,\"state\":\"disabled\"}",
        "{\"type\":\"unexpected\",\"version\":1,\"enabled\":false,\"state\":\"disabled\"}",
        "{\"type\":\"sshConfigured\",\"version\":1,\"enabled\":true,\"state\":\"unknown\"}",
        "{\"type\":\"sshConfigured\",\"version\":1,\"enabled\":true,\"state\":\"disabled\"}",
        "{\"type\":\"sshConfigured\",\"version\":1,\"enabled\":false,\"state\":\"pendingOwner\"}",
        "{\"type\":\"sshConfigured\",\"version\":1,\"enabled\":false,\"state\":\"pendingNetwork\"}",
        "{\"type\":\"sshConfigured\",\"version\":1,\"enabled\":true,\"state\":\"ready\"}",
        "{\"type\":\"sshConfigured\",\"version\":1,\"enabled\":false,\"state\":\"ready\",\"user\":\"linuxuser\",\"address\":\"192.168.64.2\",\"port\":2222,\"hostPublicKey\":\"fixture\"}",
        "{\"type\":\"sshConfigured\",\"version\":1,\"enabled\":true,\"state\":\"ready\",\"user\":\"linuxuser\",\"address\":\"192.168.64.2\",\"port\":22,\"hostPublicKey\":\"fixture\"}",
    ])
    func rejectsMalformedOrIncompatibleReplies(_ json: String) throws {
        let response = try JSONDecoder().decode(SSHGuestResponse.self, from: Data(json.utf8))
        #expect(throws: SSHAccessError.invalidResponse) { try response.validated() }
    }

    @Test(arguments: ["pendingOwner", "pendingNetwork"])
    func acceptsPendingRepliesWithoutExposingAConnection(_ state: String) throws {
        let response = SSHGuestResponse(type: "sshConfigured", version: 1, enabled: true, state: state, port: 2_222)
        expectNoDifference(try response.validated(), response)
        #expect(response.user == nil)
        #expect(response.address == nil)
        #expect(response.hostPublicKey == nil)
    }

    @Test func boundsGuestErrorTextBeforeDisplayingIt() {
        let message = String(repeating: "x", count: 1_000)
        let response = SSHGuestResponse(type: "sshError", version: 1, message: message)
        #expect(throws: SSHAccessError.guestRejected(String(repeating: "x", count: 300))) { try response.validated() }
    }

    @Test func olderPreferencesKeepSSHDisabledWithoutAnyFolderAuthorization() throws {
        let preferences = try JSONDecoder().decode(VMPreferences.self, from: Data("{}".utf8))
        #expect(!preferences.sshEnabled)
        #expect(!preferences.sshNeedsDisable)
        #expect(preferences.sshFolderBookmark == nil)
        #expect(preferences.sshFolderPath == nil)
        #expect(preferences.sshPublicKeyName == nil)
        #expect(preferences.sshManagedFiles == nil)
        expectNoDifference(preferences.sshAlias, "omabox")
    }
}
