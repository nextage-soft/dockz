import Foundation

/// Portainer-style "Edit & Recreate": docker cannot change env/volumes/ports
/// of an existing container, so the edited config is validated by creating a
/// temporary container first, then the old one is removed and the new one
/// takes over its name.
extension DashboardStore {
    struct EditContainerPayload: Identifiable {
        let id: String            // container id being edited
        let originalName: String
        let form: RunContainerForm
        let baseInspect: [String: Any]
    }

    func beginEditContainer(_ container: ContainerSummary) {
        guard let api = apiProvider() else { return }
        api.inspectContainerDict(id: container.id) { [weak self] inspect in
            DispatchQueue.main.async {
                guard let self, let inspect else {
                    self?.lastError = "Could not inspect \(container.name)"
                    return
                }
                self.editPayload = EditContainerPayload(
                    id: container.id,
                    originalName: container.name,
                    form: ContainerConfigBuilder.formFromInspect(inspect),
                    baseInspect: inspect
                )
            }
        }
    }

    func applyEditedContainer(_ payload: EditContainerPayload, form: RunContainerForm, completion: @escaping (Bool) -> Void) {
        guard let api = apiProvider() else {
            completion(false)
            return
        }
        busyIDs.insert("edit-container")
        let finish: (String?) -> Void = { [weak self] errorMessage in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyIDs.remove("edit-container")
                if let errorMessage { self.lastError = errorMessage }
                self.closeDetail()
                self.refreshAll()
                completion(errorMessage == nil)
            }
        }

        let merged = ContainerConfigBuilder.mergeForEdit(base: payload.baseInspect, form: form)
        let finalName = form.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? payload.originalName
            : form.name.trimmingCharacters(in: .whitespaces)
        let temporaryName = "\(payload.originalName)-dockz-edit"

        // Clear any leftover from a previously failed edit, then validate the
        // new config by creating the replacement under a temporary name.
        let auth = pullAuthHeader(forImageRef: form.image)
        api.removeContainer(id: temporaryName) { _ in
            api.createContainer(name: temporaryName, config: merged, pullAuthHeader: auth) { newID, createError in
                guard let newID else {
                    finish("Edit not applied (old container untouched): \(createError ?? "create failed")")
                    return
                }
                api.removeContainer(id: payload.id) { removeError in
                    if let removeError {
                        api.removeContainer(id: newID) { _ in }
                        finish("Could not replace container: \(removeError)")
                        return
                    }
                    api.renameContainer(id: newID, to: finalName) { renameError in
                        api.containerAction("start", id: newID) { startError in
                            if let renameError {
                                finish("Recreated as \(temporaryName) — \(renameError)")
                            } else {
                                finish(startError.map { "Recreated but failed to start: \($0)" })
                            }
                        }
                    }
                }
            }
        }
    }
}
