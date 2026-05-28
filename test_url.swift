import Foundation
let str = "rtmp://YOUR_RTMP_HOST/live/demo?token=YOUR_TOKEN"
guard let url = URL(string: str), let host = url.host else { print("parse failed"); exit(1) }
let port = UInt16(url.port ?? 1935)
let comps = url.path.split(separator: "/").map(String.init)
let app = comps.first ?? "live"
let stream = comps.dropFirst().joined(separator: "/") + (url.query.map { "?\($0)" } ?? "")
print("host: \(host), port: \(port), app: \(app), stream: \(stream)")
