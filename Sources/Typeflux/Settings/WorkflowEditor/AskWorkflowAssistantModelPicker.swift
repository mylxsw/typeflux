import SwiftUI

/// The workflow composer uses the same selectable model menu as Ask conversations.
struct AskWorkflowAssistantModelPicker: View {
    @ObservedObject var assistant: AskWorkflowAssistant

    var body: some View {
        AskModelMenu(library: assistant.modelLibrary, reference: Binding(
            get: { assistant.modelReference(local: assistant.keepsLocally) ?? "" },
            set: { assistant.selectModel($0) }
        ), disabled: assistant.isBusy, showsDefaultAction: false, compact: true,
           cloudAvailable: assistant.canUseCloudModels)
            .accessibilityIdentifier("ask.workflow.assistant.model")
    }
}
