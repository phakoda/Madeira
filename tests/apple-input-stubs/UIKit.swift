// Test-only boundaries. These declarations do NOT validate Apple SDK ABI/API availability.
@_exported import Foundation
public final class UIApplication {
    public enum State { case active, inactive, background }
    public static let shared = UIApplication()
    public var applicationState = State.active
    public static let didBecomeActiveNotification = Notification.Name("app-active")
    public static let willResignActiveNotification = Notification.Name("app-inactive")
}
