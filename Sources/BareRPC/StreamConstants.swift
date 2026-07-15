struct StreamFlag {
  static let open: UInt = 0x1
  static let close: UInt = 0x2
  static let pause: UInt = 0x4
  static let resume: UInt = 0x8
  static let data: UInt = 0x10
  static let end: UInt = 0x20
  static let destroy: UInt = 0x40
  static let error: UInt = 0x80
  static let request: UInt = 0x100
  static let response: UInt = 0x200
}
