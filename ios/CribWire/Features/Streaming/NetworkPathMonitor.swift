import Foundation
import Network

/// Reports when the device changes network path — the Wi-Fi→cellular switch
/// `ios-app.md` §3 requires the stream to survive.
///
/// The engine cannot infer this from ICE alone: ICE notices a dead path only
/// after its own timers expire, which is several seconds of black screen. A path
/// change is the earliest possible signal, and it is what lets the engine start
/// an ICE restart while the old path is still nominally up.
///
/// Only *changes* are reported, and only once the first path has been seen, so
/// starting the monitor does not itself look like a switch.
@MainActor
final class NetworkPathMonitor {

    /// What the device is currently using. Compared to spot a real switch: a
    /// path update that keeps the same interface (a new DHCP lease, say) is not
    /// worth an ICE restart.
    enum Interface: Equatable {
        case wifi
        case cellular
        case wired
        case other
        case unsatisfied
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.ralphhees.cribwire.path")
    private var current: Interface?
    private var isRunning = false

    private let onChange: (Interface) -> Void

    init(onChange: @escaping (Interface) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.pathUpdateHandler = { [weak self] path in
            let interface = Self.interface(of: path)
            Task { @MainActor in
                self?.handle(interface)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    private func handle(_ interface: Interface) {
        guard isRunning else { return }
        defer { current = interface }
        // The first path is the baseline, not a change.
        guard let previous = current, previous != interface else { return }
        onChange(interface)
    }

    /// Called from `NWPathMonitor`'s own queue, so it must not be actor-bound.
    private nonisolated static func interface(of path: NWPath) -> Interface {
        guard path.status == .satisfied else { return .unsatisfied }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }
}
