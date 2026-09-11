// Test devices deliver callbacks explicitly; this is not an iOS event simulator.
import Foundation
public final class GCControllerButtonInput {
    public var pressedChangedHandler: ((GCControllerButtonInput, Float, Bool) -> Void)?
    public init() {}
    public func send(_ pressed: Bool) { pressedChangedHandler?(self, pressed ? 1 : 0, pressed) }
}
public final class GCControllerDirectionPad {
    public var valueChangedHandler: ((GCControllerDirectionPad, Float, Float) -> Void)?
    public init() {}
    public func send(_ x: Float, _ y: Float) { valueChangedHandler?(self, x, y) }
}
public final class GCMouseInput {
    public var mouseMovedHandler: ((GCMouseInput, Float, Float) -> Void)?
    public let leftButton = GCControllerButtonInput()
    public var rightButton: GCControllerButtonInput? = GCControllerButtonInput()
    public var middleButton: GCControllerButtonInput? = GCControllerButtonInput()
    public var auxiliaryButtons: [GCControllerButtonInput]? = [GCControllerButtonInput(), GCControllerButtonInput()]
    public let scroll = GCControllerDirectionPad()
    public init() {}
    public func move(_ x: Float, _ y: Float) { mouseMovedHandler?(self, x, y) }
}
public final class GCMouse {
    public static var devices: [GCMouse] = []
    public static func mice() -> [GCMouse] { devices }
    public var mouseInput: GCMouseInput? = GCMouseInput()
    public var handlerQueue = DispatchQueue.global()
    public init() {}
}
public extension Notification.Name {
    static let GCMouseDidConnect = Notification.Name("mouse-connect")
    static let GCMouseDidDisconnect = Notification.Name("mouse-disconnect")
}
