import Foundation
import Observation

/// Polls a provider for one (line, stop) and publishes progress. UI-facing.
@Observable
final class BusTracker {
    let provider: any TransitProvider
    let line: TransitLine
    let stop: TransitStop

    private(set) var geometry: RouteGeometry?
    private(set) var progress: BusProgress?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    private let service = BusProgressService()
    private var task: Task<Void, Never>?

    init(provider: any TransitProvider, line: TransitLine, stop: TransitStop) {
        self.provider = provider
        self.line = line
        self.stop = stop
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.provider.suggestedRefreshInterval)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if geometry == nil {
                geometry = RouteGeometry(pattern: try await provider.routePattern(for: line))
            }
            progress = try await service.progress(provider: provider, geometry: geometry!, line: line, stop: stop)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
