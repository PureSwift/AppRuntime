import XCTest
import DynamicFormatting
import DynamicRuntime

/// Pins the formatting contracts' names, keys and wire signatures.
final class DynamicFormattingTests: XCTestCase {

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func testFormatting() {
        XCTAssertEqual(method(NumberFormatProxy.descriptor, "make:style:"), MethodDescriptor("make:style:", "(OI)O", .constructor))
        XCTAssertEqual(method(DateFormatProxy.descriptor, "formatRelative:reference:")?.signature, Signature("(JJ)O"))
        XCTAssertEqual(method(LocaleInfoProxy.descriptor, "preferredLanguages")?.kind, .static)
        XCTAssertNil(LocaleInfoProxy.descriptor.capability)
    }

    func testRecordsRoundTrip() {
        let descriptors = [NumberFormatProxy.descriptor, DateFormatProxy.descriptor, LocaleInfoProxy.descriptor]
        XCTAssertEqual(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)), descriptors)
    }
}
