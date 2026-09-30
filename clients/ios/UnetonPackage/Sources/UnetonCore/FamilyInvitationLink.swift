import Foundation

/// Shared validation for Universal Links, legacy links, and scanned invitations.
public enum FamilyInvitationLink {
  public static func url(token: String) -> URL? {
    guard isValidToken(token) else { return nil }
    return URL(string: "https://api.uneton.app/invite/\(token)")
  }

  public static func token(from url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil, components.port == nil,
      components.fragment == nil
    else { return nil }

    let prefix: String
    switch (components.scheme?.lowercased(), components.host?.lowercased()) {
    case ("https", "api.uneton.app"): prefix = "/invite/"
    case ("uneton", "invite"): prefix = "/"
    default: return nil
    }
    let path = components.percentEncodedPath
    guard path.hasPrefix(prefix) else { return nil }
    let token = String(path.dropFirst(prefix.count))
    return isValidToken(token) ? token : nil
  }

  private static func isValidToken(_ token: String) -> Bool {
    (1...128).contains(token.utf8.count) && token.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        || $0 == 45 || $0 == 95
    }
  }
}
