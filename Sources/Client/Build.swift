/// Which build this is. The app and the `atelier` command both compile this
/// in, so each knows its own build and the two can be compared. A release
/// writes the two values before it builds; anything else is a development build.
public enum Build {
  /// The version, such as 0.1.0.
  public static let version = "0.0.0"
  /// The build within the version, which a dev release advances every time.
  public static let number = "0"

  /// As shown to a person: 0.1.0 (20260918123456).
  public static let description = "\(version) (\(number))"
}
