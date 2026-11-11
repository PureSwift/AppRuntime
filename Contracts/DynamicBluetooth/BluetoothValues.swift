@_exported import Bluetooth
@_exported import BluetoothGATT

// Types from PureSwift/Bluetooth, used by the contracts in this module.
//
// `BluetoothUUID` travels as its raw string, in one of three forms: `180D`
// (16-bit), `0000180D` (32-bit) or `0000180D-0000-1000-8000-00805F9B34FB`
// (128-bit). Hosts whose platform already uses those forms pass them straight
// through (CoreBluetooth). Hosts that only have full 128-bit UUIDs convert
// (Android, BlueZ): they expand short forms on the way in, and on the way out
// shorten any UUID built on the Bluetooth Base UUID.
//
// `BluetoothUUID` compares by form, so `.bit16(0x180D)` isn't equal to the same
// UUID spelled as `.bit128`. Compare `.bit128` values when forms may differ.

public extension Peripheral {

    /// The Bluetooth address, on hosts whose identifier is one (Android,
    /// Linux). Nil on Apple platforms, which never expose addresses.
    var address: BluetoothAddress? {
        BluetoothAddress(rawValue: identifier())
    }
}

public extension Characteristic {

    var gattProperties: GATTCharacteristicProperties {
        GATTCharacteristicProperties(rawValue: UInt8(truncatingIfNeeded: properties()))
    }
}

public extension Advertisement {

    /// The company identifier that starts the manufacturer data.
    var companyIdentifier: CompanyIdentifier? {
        guard let data = manufacturerData(), data.count >= 2 else { return nil }
        return CompanyIdentifier(rawValue: UInt16(data[0]) | UInt16(data[1]) << 8)
    }
}
