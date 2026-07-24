import Foundation

/// Fetches the raw JSON for a repository's latest release. Abstracted so the checker
/// is tested with scripted responses instead of the network.
protocol ReleaseFetching: Sendable {
  func fetchLatestReleaseJSON() async throws -> Data
}

/// Hits GitHub's public REST endpoint for the latest release. No authentication: the
/// endpoint is public and the request sends nothing about the user — a bare GET with a
/// User-Agent, which GitHub requires.
struct GitHubReleaseFetcher: ReleaseFetching {
  /// The project repository as `owner/repo`.
  let repository: String
  let session: URLSession

  init(repository: String, session: URLSession = .shared) {
    self.repository = repository
    self.session = session
  }

  enum FetchError: Error, Equatable {
    case badURL
    case badStatus(Int)
  }

  func fetchLatestReleaseJSON() async throws -> Data {
    guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
      throw FetchError.badURL
    }
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    // GitHub rejects requests without a User-Agent; the app name suffices and says
    // nothing about the user.
    request.setValue("Perch", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 15
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw FetchError.badStatus(http.statusCode)
    }
    return data
  }
}
