/// Isolated unit-test substitute for the application-only preview/demo flag.
/// Production builds compile the real definition from Sources/Startup.swift.
enum TranslatorRuntime {
    static let isDemoBuild = false
}
