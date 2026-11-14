// Linux-only test doubles for unavailable Apple framework interfaces.
// They do not validate Combine notifications or SwiftUI rendering.
public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
