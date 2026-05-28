import Foundation
var c = try! String(contentsOfFile: "livestream/StreamUploader.swift")

c = c.replacingOccurrences(of: """
        let remaining = buffer.count - index
        if remaining < need {
            SharedLogger.log("等待Payload: fmt=\\(fmt), csid=\\(csid), remaining=\\(remaining) < need=\\(need), msgLen=\\(state.header.messageLength), recv=\\(state.received)")
            return nil 
        }
        SharedLogger.log("Chunk解析: fmt=\\(fmt), csid=\\(csid), len=\\(state.header.messageLength), need=\\(need), rem=\\(remaining)")
""", with: """
        let remaining = buffer.count - index
        if remaining < need {
            return nil 
        }
""")

c = c.replacingOccurrences(of: """
        let headerLen = fmt == 0 ? 11 : (fmt == 1 ? 7 : (fmt == 2 ? 3 : 0))
        guard buffer.count >= index + headerLen else { 
            SharedLogger.log("等待头部: buffer=\\(buffer.count), need=\\(index + headerLen)")
            return nil 
        }
""", with: """
        let headerLen = fmt == 0 ? 11 : (fmt == 1 ? 7 : (fmt == 2 ? 3 : 0))
        guard buffer.count >= index + headerLen else { return nil }
""")

try! c.write(toFile: "livestream/StreamUploader.swift", atomically: true, encoding: .utf8)
