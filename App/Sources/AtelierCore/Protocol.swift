import Foundation

public struct EngineRequest: Codable, Sendable {
  public var id: Int = 0
  public var command: String
  public var number: Int?
  public var offset: Int?
  public var display: String?
  public var current: String?
  public var app: String?
  public var expectedBundleID: String?
  public var size: QuickApp.Size?
  public var window: UInt32?
  public var pid: Int32?
  public var space: String?
  public init(_ command: String) { self.command = command }
}

public struct EngineHello: Decodable {
  public let protocolVersion: Int
  public let pid: Int32
  public let trusted: Bool
}
public struct ResolvedApplication: Decodable {
  public let bundleID: String
  public let name: String
}
public struct EmptyResult: Decodable {}
