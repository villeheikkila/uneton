import Foundation
import Testing
@testable import UnetonCore

struct FamilyInvitationLinkTests {
  @Test func sharedLinksUseHTTPSAndRoundTrip() throws {
    let token = "abcdefghijklmnopqrstuvwxyz0123456789_AB-CDxy"
    let url = try #require(FamilyInvitationLink.url(token: token))
    #expect(url.absoluteString == "https://api.uneton.app/invite/\(token)")
    #expect(FamilyInvitationLink.token(from: url) == token)
    #expect(FamilyInvitationLink.token(from: URL(string: "uneton://invite/\(token)")!) == token)
    #expect(FamilyInvitationLink.token(from: URL(string: "\(url)?lang=fi")!) == token)
  }

  @Test(arguments: [
    "http://api.uneton.app/invite/token", "https://example.com/invite/token",
    "https://api.uneton.app.evil.test/invite/token", "https://api.uneton.app/invite/",
    "https://api.uneton.app/invite/token/extra", "https://api.uneton.app/invite/token/",
    "https://user@api.uneton.app/invite/token", "https://api.uneton.app:443/invite/token",
    "https://api.uneton.app/invite/token#fragment", "https://api.uneton.app/invite/token%2Fextra",
    "https://api.uneton.app/invite/%74oken", "uneton://invite/", "uneton://invite/token/extra",
    "uneton://sleep/end", "https://api.uneton.app/privacy",
  ]) func unrelatedAndMalformedLinksAreRejected(_ value: String) {
    #expect(FamilyInvitationLink.token(from: URL(string: value)!) == nil)
  }

  @Test(arguments: ["", "token/extra", "token?query", "token#fragment", "token with space", "kutsuä", String(repeating: "a", count: 129)])
  func unsafeTokensCannotBeShared(_ token: String) {
    #expect(FamilyInvitationLink.url(token: token) == nil)
  }
}
