import Foundation
var c = try! String(contentsOfFile: "livestream/StreamUploader.swift")

c = c.replacingOccurrences(of: """
                SharedLogger.log("接收到网络数据: \\(data.count) bytes")
""", with: """
                SharedLogger.log("接收到网络数据: \\(data.count) bytes")
                SharedLogger.log("HEX: \\(data.map { String(format: "%02hhX", $0) }.joined().prefix(100))...")
""")

try! c.write(toFile: "livestream/StreamUploader.swift", atomically: true, encoding: .utf8)
