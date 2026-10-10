import Foundation

extension AskConversationModel {
    func scheduleTitle(_ value: AskConversation, route: AskRoute) {
        let settings = modelLibrary.settings
        guard settings.askAutomaticTitles, value.titleSource != "auto", value.titleSource != "manual",
              value.run?.status == "completed", AskConversationTitle.transcript(value) != nil,
              titleTasks[value.id] == nil, (titleRetryAfter[value.id] ?? .distantPast) < Date(),
              (value.titleGeneration?.attempts ?? 0) < 3 else { return }
        let id = value.id
        let preference = settings.askTitleModelReference
        // Local storage never implicitly selects a Cloud provider for metadata.
        let reference = preference.isEmpty ? (route.token.isEmpty ? value.modelRef ?? "" : "cloud:default") : preference
        if route.token.isEmpty, reference.hasPrefix("cloud:") { return }
        titleTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if owner == route.account, !isDeletedConversation(id) {
                    titleTasks[id] = nil
                    titleRetryAfter[id] = Date().addingTimeInterval(60)
                }
            }
            let taskID = UUID().uuidString.lowercased()
            let cloud = reference.hasPrefix("cloud:") && !route.token.isEmpty
            do {
                var snapshot = try await api.updateTitle(id: id, request: .init(action: cloud ? "generate" : "claim", id: taskID,
                                                                              modelRef: cloud ? reference : nil), token: route.token)
                try await accept(snapshot, route: route)
                if !cloud, snapshot.titleGeneration?.id == taskID, snapshot.titleGeneration?.status == "pending" {
                    guard let transcript = AskConversationTitle.transcript(snapshot),
                          let (provider, model) = modelLibrary.registry.resolve(reference), !provider.isCloud else {
                        throw AskLocalError.message(L("ask.models.unavailable"))
                    }
                    let payload: [String: Any] = ["messages": [["role": "system", "content": AskConversationTitle.prompt],
                                                             ["role": "user", "content": transcript]],
                                                  "max_tokens": 128, "typeflux_budget": true,
                                                  "typeflux_deadline": Date().addingTimeInterval(20).timeIntervalSince1970]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    let (text, calls) = try await customInference.complete(provider: provider,
                        connection: modelLibrary.connection(provider, model: model), payload: String(decoding: data, as: UTF8.self))
                    guard calls.isEmpty else { throw AskLocalError.message(L("ask.models.requestError")) }
                    let title = try AskConversationTitle.clean(text)
                    // A follow-up may have started during inference. Wait without
                    // changing its revision or replacing its transcript.
                    for _ in 0..<120 {
                        try Task.checkCancellation()
                        guard owner == route.account, !isDeletedConversation(id) else { return }
                        let latest = try await api.conversation(id: id, token: route.token)
                        if latest.titleSource == "manual" || latest.titleSource == "auto" { return }
                        if latest.run?.isActive != true {
                            do {
                                snapshot = try await api.updateTitle(id: id, request: .init(action: "complete", id: taskID, title: title), token: route.token)
                                try await accept(snapshot, route: route)
                                return
                            } catch { /* A concurrent send can win; retry the metadata receipt. */ }
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }
                // Chat observation stops at the final answer, so metadata has its
                // own bounded poll that also handles a task claimed on another device.
                for _ in 0..<50 {
                    guard owner == route.account, !isDeletedConversation(id), snapshot.titleGeneration?.status == "pending" else { return }
                    try await Task.sleep(for: .seconds(1))
                    snapshot = try await api.conversation(id: id, token: route.token)
                    try await accept(snapshot, route: route)
                }
            } catch {
                guard !Task.isCancelled, owner == route.account, !isDeletedConversation(id) else { return }
                if let failed = try? await api.updateTitle(id: id, request: .init(action: "fail", id: taskID), token: route.token) {
                    try? await accept(failed, route: route)
                }
            }
        }
    }

    func renameConversation(_ id: String, title: String) async throws {
        guard let route = credentials(for: id) else { throw AuthError.unauthorized }
        let title = try AskConversationTitle.clean(title)
        let value = try await api.updateTitle(id: id, request: .init(action: "rename", title: title), token: route.token)
        titleTasks[id]?.cancel(); titleTasks[id] = nil
        try await accept(value, route: route)
    }

}
