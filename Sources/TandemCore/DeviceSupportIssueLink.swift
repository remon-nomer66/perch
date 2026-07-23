import Foundation

/// 対応申請をどう開くか。
///
/// 本文をURLへ載せられるとは限らない。機器が申告する機能の数は機種によって数十件に
/// なり、日本語はpercent-encodingでおよそ8倍に膨らむ。収まらない場合に黙って本文を
/// 切り詰めると、申請者が送ったつもりの内容と実際に送られる内容が食い違う。収まるか
/// 収まらないかを呼び出し側へ返し、扱いを選ばせる。
public enum TandemIssueDestination: Equatable, Sendable {
  /// 題名と本文を入れた状態で開ける。
  case prefilled(URL)

  /// URLに収まらない。空のフォームを開き、本文は別の手段で渡す。
  ///
  /// 本文は切り詰めていない。貼り付けは申請者の操作になるため、送られる内容を
  /// 申請者自身が目で確かめる機会も保たれる。
  case bodyTooLong(form: URL, body: String)
}

public enum TandemIssueLinkError: Error, Equatable, CustomStringConvertible, Sendable {
  case malformedRepository(String)

  public var description: String {
    switch self {
    case .malformedRepository(let value):
      return "リポジトリは owner/repo の形で指定する: \(value)"
    }
  }
}

/// 対応申請のURLを組み立てる。
///
/// 送信は行わない。ここで作るのは、利用者のブラウザで開くための入り口だけである。
/// アプリから直接投稿しないため、資格情報を持つ必要がなく、また投稿する前に本人が
/// 全文を確認できる。
public enum TandemIssueLink {
  /// URL全体のバイト数の上限。
  ///
  /// 多くのHTTPサーバーが要求行を8KiBで打ち切るため、それより内側に置く。GitHubが
  /// 公表している値ではなく、安全側に寄せた見積もりである。
  public static let conservativeURLByteLimit = 8_000

  /// 本文を載せるクエリパラメータの既定値。
  ///
  /// Markdownテンプレートでは `body` が本文を指す。Issue Formでは代わりに、本文を
  /// 入れたいフィールドの `id` を指定する。どちらの形式でも同じ組み立てで済むよう、
  /// 名前を呼び出し側から与えられるようにしてある。
  public static let markdownTemplateBodyParameter = "body"

  public static func destination(
    repository: String,
    report: TandemDeviceSupportReport,
    template: String? = nil,
    labels: [String] = [],
    bodyParameter: String = markdownTemplateBodyParameter,
    byteLimit: Int = conservativeURLByteLimit
  ) throws -> TandemIssueDestination {
    let base = try issueFormURL(repository: repository)

    var query: [(String, String)] = []
    if let template { query.append(("template", template)) }
    if !labels.isEmpty { query.append(("labels", labels.joined(separator: ","))) }
    query.append(("title", report.title))
    query.append((bodyParameter, report.body))

    let prefilled = base + "?" + query
      .map { "\($0.0)=\(Self.percentEncoded($0.1))" }
      .joined(separator: "&")

    if prefilled.utf8.count <= byteLimit, let url = URL(string: prefilled) {
      return .prefilled(url)
    }

    // 本文だけを落として題名は残す。何を申請しようとしていたかが開いた画面に残る。
    let fallbackQuery = query.filter { $0.0 != bodyParameter }
    let form = fallbackQuery.isEmpty
      ? base
      : base + "?" + fallbackQuery
        .map { "\($0.0)=\(Self.percentEncoded($0.1))" }
        .joined(separator: "&")

    guard let url = URL(string: form) else {
      throw TandemIssueLinkError.malformedRepository(repository)
    }
    return .bodyTooLong(form: url, body: report.body)
  }

  // MARK: - Private

  private static func issueFormURL(repository: String) throws -> String {
    let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      throw TandemIssueLinkError.malformedRepository(repository)
    }
    // owner と repo に使える文字はGitHubの規則に合わせて限る。ここを緩めると、
    // 設定値の誤りがそのままURLの構造を変えてしまう。
    let allowed = CharacterSet(charactersIn:
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    for part in parts {
      guard !part.isEmpty,
            part.unicodeScalars.allSatisfy({ allowed.contains($0) })
      else {
        throw TandemIssueLinkError.malformedRepository(repository)
      }
    }
    return "https://github.com/\(parts[0])/\(parts[1])/issues/new"
  }

  /// RFC 3986 の unreserved 以外をすべて退避する。
  ///
  /// `URLComponents` は `+` を素通しし、受け側によっては空白と解釈される。本文には
  /// 任意の文字が入りうるので、残す文字を最小限に決めておく。
  static func percentEncoded(_ value: String) -> String {
    let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    var out = ""
    out.reserveCapacity(value.utf8.count * 3)
    for byte in value.utf8 {
      if unreserved.contains(byte) {
        out.append(Character(UnicodeScalar(byte)))
      } else {
        out += String(format: "%%%02X", byte)
      }
    }
    return out
  }
}
