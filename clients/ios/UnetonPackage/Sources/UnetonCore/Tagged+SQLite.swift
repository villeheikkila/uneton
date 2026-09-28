import SQLiteData
import Tagged

// Xcode does not propagate SQLiteData's Tagged package trait through this local
// package. Keep the equivalent conformances here so SwiftPM and Xcode agree.
extension Tagged: @retroactive _OptionalPromotable where RawValue: _OptionalPromotable {}
extension Tagged: @retroactive QueryBindable where RawValue: QueryBindable {}
extension Tagged: @retroactive QueryDecodable where RawValue: QueryDecodable {}
extension Tagged: @retroactive QueryExpression where RawValue: QueryExpression {
  public var queryFragment: QueryFragment { rawValue.queryFragment }
}
extension Tagged: @retroactive QueryRepresentable where RawValue: QueryRepresentable {
  public typealias QueryOutput = Tagged<Tag, RawValue.QueryOutput>

  public var queryOutput: QueryOutput {
    QueryOutput(rawValue: rawValue.queryOutput)
  }

  public init(queryOutput: QueryOutput) {
    self.init(rawValue: RawValue(queryOutput: queryOutput.rawValue))
  }

  public static func queryFragment(decoding queryFragment: QueryFragment) -> QueryFragment {
    RawValue.queryFragment(decoding: queryFragment)
  }

  public static func _queryFragment(jsonEncoding queryFragment: QueryFragment) -> QueryFragment {
    RawValue._queryFragment(jsonEncoding: queryFragment)
  }

  public static func _queryFragment(jsonDecoding queryFragment: QueryFragment) -> QueryFragment {
    RawValue._queryFragment(jsonDecoding: queryFragment)
  }
}
