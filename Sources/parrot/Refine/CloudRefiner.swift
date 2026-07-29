import Foundation

/// Transcript cleanup via an OpenAI-compatible chat-completions endpoint.
///
/// Stronger than the on-device model, but transcript text leaves the machine,
/// so this is never a default. The API key is read from the environment only.
struct CloudRefiner: Refiner {
    let config: RefineConfig
    let apiKey: String

    func refine(_ text: String, style: String?) async throws -> String {
        let trimmedBase = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/chat/completions") else {
            throw RefineError.badResponse("invalid base URL: \(config.baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = RefineConfig.timeout + 2

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.0,
            "messages": [
                ["role": "system", "content": RefinePrompt.instructions],
                ["role": "user", "content": RefinePrompt.userMessage(text: text, style: style)],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await withTimeout(seconds: RefineConfig.timeout) {
            try await URLSession.shared.data(for: request)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RefineError.badResponse("not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw RefineError.badResponse("HTTP \(http.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw RefineError.badResponse("could not parse chat completion response")
        }

        let cleaned = RefinePrompt.cleanResponse(content)
        guard !cleaned.isEmpty else { throw RefineError.emptyResult }
        return cleaned
    }
}
