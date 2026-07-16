import AppKit
import Foundation

extension DashboardStore {
    // MARK: - Run container

    func runContainer(_ form: RunContainerForm, completion: @escaping (Bool) -> Void) {
        guard let api = apiProvider(), !form.image.trimmingCharacters(in: .whitespaces).isEmpty else {
            completion(false)
            return
        }
        busyIDs.insert("run-container")
        let config = ContainerConfigBuilder.buildCreateConfig(form)
        let auth = pullAuthHeader(forImageRef: form.image)
        api.createAndStartContainer(name: form.name, config: config, pullAuthHeader: auth) { [weak self] errorMessage in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyIDs.remove("run-container")
                if let errorMessage { self.lastError = errorMessage }
                self.refreshAll()
                completion(errorMessage == nil)
            }
        }
    }

    // MARK: - Pull image

    func pullImage(reference: String) {
        guard let api = apiProvider(), !reference.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        busyIDs.insert("pull-image")
        api.pullImage(reference: reference, authHeader: pullAuthHeader(forImageRef: reference)) { [weak self] errorMessage in
            DispatchQueue.main.async {
                self?.busyIDs.remove("pull-image")
                if let errorMessage { self?.lastError = "Pull failed: \(errorMessage)" }
                self?.refreshAll()
            }
        }
    }

    // MARK: - Restart policy

    func updateRestartPolicy(_ policy: String) {
        guard let api = apiProvider(), let container = selectedContainer else { return }
        api.updateRestartPolicy(id: container.id, policy: policy) { [weak self] errorMessage in
            DispatchQueue.main.async {
                if let errorMessage { self?.lastError = errorMessage }
                self?.reloadDetail()
            }
        }
    }

    // MARK: - Networks

    func createNetwork(name: String) {
        run(busyKey: "create-network") { api, done in api.createNetwork(name: name, completion: done) }
    }

    func removeNetwork(_ network: NetworkSummary) {
        run(busyKey: network.id) { api, done in
            api.requestData(method: "DELETE", path: "/networks/\(network.id)") { result in
                switch result {
                case .failure(let error): done(error.localizedDescription)
                case .success(let response): done(response.status < 300 ? nil : "HTTP \(response.status)")
                }
            }
        }
    }

    func pruneNetworks() {
        run(busyKey: "prune-networks") { api, done in
            api.requestData(method: "POST", path: "/networks/prune") { result in
                switch result {
                case .failure(let error): done(error.localizedDescription)
                case .success: done(nil)
                }
            }
        }
    }

    func openNetworkInspect(_ network: NetworkSummary) {
        guard let api = apiProvider() else { return }
        api.inspectNetwork(id: network.id) { [weak self] json in
            DispatchQueue.main.async {
                self?.imageInspect = ImageInspectPayload(id: network.id, title: "network: \(network.name)", json: json)
            }
        }
    }

}
