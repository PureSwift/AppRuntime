/// Guest-side names for what the `Contacts` contract carries.

/// Whether the app may use the user's contacts.
public enum ContactStoreAccess: Int32, Sendable {

    /// The user hasn't been asked.
    case notDetermined = 0

    /// Parental controls or device management prevent access.
    case restricted = 1

    /// The user refused, or the manifest doesn't declare `.contacts`.
    case denied = 2

    case authorized = 3

    /// The contacts the user chose, and what the app adds.
    case limited = 4

    /// This host has no contacts store.
    case unavailable = 5

    /// Whether the store can be read at all.
    public var allowsReading: Bool {
        self == .authorized || self == .limited
    }
}

/// Why a contacts call failed.
public enum ContactStoreError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. The operation may
    /// still happen. Hosts never send it.
    case cancelled = 1

    /// No access, or a write by an app that declared reading alone.
    case notAuthorized = 2

    /// This host has no contacts store.
    case unavailable = 3

    /// The contact is gone.
    case notFound = 4

    /// This person can't be changed: a company directory, a linked
    /// service.
    case readOnly = 5

    /// A contact with nothing in it.
    case invalidContact = 6
}

/// Which of a person's numbers or addresses a value is: one of the eight
/// every host knows, or text of the user's own.
public struct ContactLabel: RawRepresentable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A label of the user's own.
    public init(_ text: String) {
        self.rawValue = text
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let home = ContactLabel(rawValue: "home")
    public static let work = ContactLabel(rawValue: "work")
    public static let mobile = ContactLabel(rawValue: "mobile")
    public static let main = ContactLabel(rawValue: "main")
    public static let other = ContactLabel(rawValue: "other")
    public static let homeFax = ContactLabel(rawValue: "homeFax")
    public static let workFax = ContactLabel(rawValue: "workFax")
    public static let pager = ContactLabel(rawValue: "pager")

    /// The eight every host has a word for.
    public static let standard: [ContactLabel] = [.home, .work, .mobile, .main, .other, .homeFax, .workFax, .pager]

    /// Whether it's one the app has a translation for, and not the
    /// user's own text.
    public var isStandard: Bool {
        Self.standard.contains(self)
    }
}

/// A value and which one it is: a work email, a mobile number.
public struct LabeledValue<Value: Hashable & Sendable>: Equatable, Hashable, Sendable {

    public var label: ContactLabel

    public var value: Value

    public init(_ label: ContactLabel, _ value: Value) {
        self.label = label
        self.value = value
    }
}

/// Where someone lives or works.
public struct PostalAddress: Equatable, Hashable, Sendable {

    public var street: String

    public var city: String

    /// A state, a province, a county.
    public var region: String

    public var postalCode: String

    public var country: String

    /// Two letters, such as `IE`.
    public var isoCountryCode: String

    public init(street: String = "", city: String = "", region: String = "", postalCode: String = "", country: String = "", isoCountryCode: String = "") {
        self.street = street
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.isoCountryCode = isoCountryCode
    }

    public var isEmpty: Bool {
        street.isEmpty && city.isEmpty && region.isEmpty && postalCode.isEmpty && country.isEmpty && isoCountryCode.isEmpty
    }
}

/// A day of the year, and the year when it's known: a birthday.
public struct ContactDate: Equatable, Hashable, Sendable {

    public var year: Int?

    public var month: Int

    public var day: Int

    public init(year: Int? = nil, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// `1815-12-10`, or `--12-10` with no year: as the contract carries
    /// it.
    public var text: String {
        func digits(_ value: Int, _ count: Int) -> String {
            var text = String(value)
            while text.utf8.count < count { text = "0" + text }
            return text
        }
        return (year.map { digits($0, 4) } ?? "-") + "-" + digits(month, 2) + "-" + digits(day, 2)
    }

    /// `nil` for text that isn't a date.
    public init?(text: String) {
        let bytes = Array(text.utf8)
        func number(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var result = 0
            for byte in bytes[start ..< start + count] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                result = result * 10 + Int(byte - 0x30)
            }
            return result
        }
        let dash = UInt8(ascii: "-")
        let year: Int?
        let rest: Int
        if bytes.count == 7, bytes[0] == dash, bytes[1] == dash {
            year = nil
            rest = 2
        } else if bytes.count == 10, bytes[4] == dash, let read = number(0, 4) {
            year = read
            rest = 5
        } else {
            return nil
        }
        guard bytes[rest + 2] == dash, let month = number(rest, 2), let day = number(rest + 3, 2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }
}

/// One person in the user's address book: every account's card of them,
/// joined, as the system's own app shows them. A value: change it and give
/// it back to the store to save.
///
/// ```swift
/// var ada = Contact()
/// ada.givenName = "Ada"
/// ada.familyName = "Lovelace"
/// ada.emailAddresses = [LabeledValue(.work, "ada@example.com")]
/// ada = try await store.save(ada)
/// ```
public struct Contact: Equatable, Hashable, Sendable {

    /// The store's identifier; `nil` until it's saved.
    public var id: String?

    /// The whole name, as the system formats it; or the organization, an
    /// email address or a phone number when there's no name. The store
    /// makes it: an app reads it.
    public private(set) var displayName: String

    public var namePrefix: String

    public var givenName: String

    public var middleName: String

    public var familyName: String

    public var nameSuffix: String

    public var nickname: String

    public var organizationName: String

    public var departmentName: String

    public var jobTitle: String

    /// As the user wrote them: nothing tidies a number.
    public var phoneNumbers: [LabeledValue<String>]

    public var emailAddresses: [LabeledValue<String>]

    public var urls: [LabeledValue<String>]

    public var postalAddresses: [LabeledValue<PostalAddress>]

    public var birthday: ContactDate?

    public init() {
        self.id = nil
        self.displayName = ""
        self.namePrefix = ""
        self.givenName = ""
        self.middleName = ""
        self.familyName = ""
        self.nameSuffix = ""
        self.nickname = ""
        self.organizationName = ""
        self.departmentName = ""
        self.jobTitle = ""
        self.phoneNumbers = []
        self.emailAddresses = []
        self.urls = []
        self.postalAddresses = []
        self.birthday = nil
    }

    /// The contact with a display name: for a store, which is what names
    /// one.
    public func named(_ displayName: String) -> Contact {
        var contact = self
        contact.displayName = displayName
        return contact
    }

    /// The nine parts of a name, in the contract's order: prefix, given,
    /// middle, family, suffix, nickname, organization, department, job
    /// title.
    public var nameParts: [String] {
        get {
            [namePrefix, givenName, middleName, familyName, nameSuffix, nickname, organizationName, departmentName, jobTitle]
        }
        set {
            func part(_ index: Int) -> String {
                index < newValue.count ? newValue[index] : ""
            }
            namePrefix = part(0)
            givenName = part(1)
            middleName = part(2)
            familyName = part(3)
            nameSuffix = part(4)
            nickname = part(5)
            organizationName = part(6)
            departmentName = part(7)
            jobTitle = part(8)
        }
    }

    /// Whether there's nothing in it: such a contact can't be saved.
    public var isEmpty: Bool {
        nameParts.allSatisfy { $0.isEmpty } && phoneNumbers.isEmpty && emailAddresses.isEmpty && urls.isEmpty
            && postalAddresses.isEmpty && birthday == nil
    }
}

extension Contact {

    /// The contact a record holds, read whole.
    public init(_ record: any ContactRecord) {
        self.init()
        let identifier = record.identifier()
        id = identifier.isEmpty ? nil : identifier
        displayName = record.displayName()
        nameParts = record.nameParts()
        phoneNumbers = Self.labeled(record.phoneLabels(), record.phoneNumbers())
        emailAddresses = Self.labeled(record.emailLabels(), record.emailAddresses())
        urls = Self.labeled(record.urlLabels(), record.urls())
        postalAddresses = Self.addresses(record.postalAddresses())
        birthday = ContactDate(text: record.birthday())
    }

    /// Fills a record in with this contact, to save or to remove.
    public func fill(_ record: any ContactRecord) {
        record.setIdentifier(id ?? "")
        record.setNameParts(nameParts)
        record.setPhones(phoneNumbers.map { $0.label.rawValue }, numbers: phoneNumbers.map { $0.value })
        record.setEmails(emailAddresses.map { $0.label.rawValue }, addresses: emailAddresses.map { $0.value })
        record.setURLs(urls.map { $0.label.rawValue }, urls: urls.map { $0.value })
        record.setPostalAddresses(Self.fields(postalAddresses))
        record.setBirthday(birthday?.text ?? "")
    }

    /// Labels and values paired; what has no partner is left out.
    public static func labeled(_ labels: [String], _ values: [String]) -> [LabeledValue<String>] {
        var result: [LabeledValue<String>] = []
        for index in 0 ..< min(labels.count, values.count) {
            result.append(LabeledValue(ContactLabel(rawValue: labels[index]), values[index]))
        }
        return result
    }

    /// Addresses as the contract carries them: seven strings for each.
    public static func fields(_ addresses: [LabeledValue<PostalAddress>]) -> [String] {
        var fields: [String] = []
        for address in addresses {
            let value = address.value
            fields += [address.label.rawValue, value.street, value.city, value.region, value.postalCode, value.country, value.isoCountryCode]
        }
        return fields
    }

    /// Whole sevens are read; a remainder is left out.
    public static func addresses(_ fields: [String]) -> [LabeledValue<PostalAddress>] {
        var result: [LabeledValue<PostalAddress>] = []
        var index = 0
        while index + 7 <= fields.count {
            result.append(LabeledValue(ContactLabel(rawValue: fields[index]), PostalAddress(
                street: fields[index + 1], city: fields[index + 2], region: fields[index + 3],
                postalCode: fields[index + 4], country: fields[index + 5], isoCountryCode: fields[index + 6]
            )))
            index += 7
        }
        return result
    }
}
