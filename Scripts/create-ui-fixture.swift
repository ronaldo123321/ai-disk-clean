import Foundation

let fm = FileManager.default
let root = "/private/tmp/dclean-ui-" + UUID().uuidString
let home = root + "/home"
try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
try Data("temporary UI acceptance fixture".utf8).write(to: URL(fileURLWithPath: root + "/.ui-fixture"))
let entries: [(String, Data)] = [
    ("Projects/atlas-web/package.json", Data("{}".utf8)),
    ("Projects/atlas-web/package-lock.json", Data("{}".utf8)),
    ("Projects/atlas-web/.next/cache.bin", Data(repeating: 0x41, count: 2 << 20)),
    ("Projects/atlas-web/node_modules/example/index.js", Data(repeating: 0x42, count: 3 << 20)),
    ("Projects/research-api/uv.lock", Data("version = 1".utf8)),
    ("Projects/research-api/main.py", Data("print('fixture')".utf8)),
    ("Projects/research-api/.venv/lib/data.bin", Data(repeating: 0x43, count: 2 << 20)),
    ("Projects/chain-demo/Cargo.toml", Data("[package]".utf8)),
    ("Projects/chain-demo/target/deploy/program-keypair.json", Data("TEST ONLY - NOT A KEY".utf8)),
    ("Projects/chain-demo/target/output.bin", Data(repeating: 0x44, count: 2 << 20))
]
for (relative, data) in entries {
    let url = URL(fileURLWithPath: home + "/" + relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
let old = Date().addingTimeInterval(-120 * 86400)
let enumerator = fm.enumerator(atPath: home)!
while let path = enumerator.nextObject() as? String {
    try fm.setAttributes([.modificationDate: old], ofItemAtPath: home + "/" + path)
}
print(home)
