import Foundation

/// 持有「浮窗对象」的强引用，防止 ARC 在窗口还在屏幕上时就 dealloc 掉。
/// 浮窗对象自己负责关闭后调用 `remove(self)`。
final class WindowRegistry {
    static let shared = WindowRegistry()
    private init() {}

    private var windows: [AnyObject] = []

    func add(_ obj: AnyObject) {
        windows.append(obj)
    }

    func remove(_ obj: AnyObject) {
        windows.removeAll { $0 === obj }
    }

    var count: Int { windows.count }
}
