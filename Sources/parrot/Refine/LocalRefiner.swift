import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// On-device transcript cleanup via Apple's FoundationModels. Nothing leaves
/// the machine; no API key, no network, no cost.
@available(macOS 26.0, *)
struct LocalRefiner: Refiner {
    func refine(_ text: String, style: String?) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw RefineError.unavailable(
                "on-device language model is \(model.availability); "
                    + "check that Apple Intelligence is enabled in System Settings"
            )
        }

        let session = LanguageModelSession(instructions: RefinePrompt.instructions)

        let response = try await withTimeout(seconds: RefineConfig.timeout) {
            try await session.respond(
                to: RefinePrompt.userMessage(text: text, style: style),
                options: GenerationOptions(temperature: 0.0)
            )
        }

        let cleaned = RefinePrompt.cleanResponse(response.content)
        guard !cleaned.isEmpty else { throw RefineError.emptyResult }
        return cleaned
    }
}

#endif
