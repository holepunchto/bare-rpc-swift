public struct StreamFlag {
  public static let OPEN: UInt = 0x1
  public static let CLOSE: UInt = 0x2
  public static let PAUSE: UInt = 0x4
  public static let RESUME: UInt = 0x8
  public static let DATA: UInt = 0x10
  public static let END: UInt = 0x20
  public static let DESTROY: UInt = 0x40
  public static let ERROR: UInt = 0x80
  public static let REQUEST: UInt = 0x100
  public static let RESPONSE: UInt = 0x200
}
