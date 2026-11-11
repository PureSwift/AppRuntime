import Testing
import DynamicFormatting
import DynamicRuntime

/// Pins the formatting contracts' names, keys and wire signatures.
@Suite struct DynamicFormattingTests {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    @Test func formatting() {
        #expect(method(NumberFormatProxy.descriptor, "make:style:") == MethodDescriptor("make:style:", "(OI)O", .constructor))
        #expect(method(DateFormatProxy.descriptor, "formatRelative:reference:")?.signature == Signature("(JJ)O"))
        #expect(method(LocaleInfoProxy.descriptor, "preferredLanguages")?.kind == .static)
        #expect(LocaleInfoProxy.descriptor.capability == nil)
    }

    @Test func recordsRoundTrip() {
        let descriptors = [NumberFormatProxy.descriptor, DateFormatProxy.descriptor, LocaleInfoProxy.descriptor]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }
}
