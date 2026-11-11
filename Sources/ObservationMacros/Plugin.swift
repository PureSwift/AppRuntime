import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ObservationMacrosPlugin: CompilerPlugin {

    let providingMacros: [any Macro.Type] = [
        ObservableMacro.self,
        ObservationTrackedMacro.self,
        ObservationIgnoredMacro.self,
    ]
}
