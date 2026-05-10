import Foundation

enum Resources {
    static var indexHTML: Data {
        load("index.html")
    }

    static var stylesCSS: Data {
        load("styles.css")
    }

    static var appJS: Data {
        load("app.js")
    }

    private static func load(_ name: String) -> Data {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("MacOSApp/Resources")
                .appendingPathComponent(name),
        ].compactMap { $0 }

        for url in candidates {
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return Data()
    }
}
