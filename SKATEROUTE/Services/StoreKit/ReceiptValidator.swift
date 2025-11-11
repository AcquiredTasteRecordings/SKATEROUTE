import Foundation
import StoreKit

public enum ReceiptValidationResult: Sendable, Equatable {
    case valid
    case invalid(reason: String)
}

public final actor ReceiptValidator {
    public init() {}
    public func validate() async -> ReceiptValidationResult {
        #if DEBUG
        return .valid
        #else
        return .invalid(reason: "Receipt validation not implemented. Use server validation.")
        #endif
    }
}
