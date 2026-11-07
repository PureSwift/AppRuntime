import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct DynamicRuntimePlugin: CompilerPlugin {

    let providingMacros: [any Macro.Type] = [
        DynamicRuntimeMacro.self,
        DynamicCallbackMacro.self,
    ]
}
