import CLlama
import Foundation

// Private disposable helper. stdout contains only line-delimited JSON; inputs are never logged.
struct Request: Decodable { var texts: [String] }
struct Response: Encodable { let entries: [String] = []; var embeddings: [[Float]]?; var error: Int32? }
enum Failure: Error { case invalidInput, inference }

final class Encoder {
    let model: OpaquePointer
    let context: OpaquePointer
    let batch: OpaquePointer

    init(path: String) throws {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(path, modelParams) else { throw Failure.inference }
        var params = llama_context_default_params()
        params.n_ctx = 2048; params.n_batch = 2048; params.n_ubatch = 2048
        params.n_seq_max = 1; params.kv_unified = true
        params.embeddings = true; params.pooling_type = LLAMA_POOLING_TYPE_MEAN
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model); throw Failure.inference
        }
        self.model = model; self.context = context
        self.batch = llama_batch_ext_init(context)!
        guard llama_model_n_embd_out(model) == 768 else { throw Failure.inference }
    }

    deinit {
        llama_batch_ext_free(batch); llama_free(context); llama_model_free(model)
        llama_backend_free()
    }

    func embed(_ text: String) throws -> [Float] {
        guard !text.isEmpty, text.utf8.count <= 1800 else { throw Failure.invalidInput }
        let bytes = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: bytes.count + 8)
        let count = llama_tokenize(llama_model_get_vocab(model), bytes, Int32(bytes.count - 1),
                                   &tokens, Int32(tokens.count), true, false)
        guard count > 0, count <= 2048 else { throw Failure.invalidInput }
        llama_batch_ext_clear(self.batch)
        defer { llama_batch_ext_clear(batch) }
        for index in 0 ..< Int(count) {
            let row = llama_batch_ext_add_token(batch, 0, tokens[index])
            var position: [llama_pos] = [llama_pos(index), 0, 0, 0]
            guard row >= 0, llama_batch_ext_set_pos(self.batch, row, &position),
                  llama_batch_ext_set_output_embd(self.batch, row, true) else { throw Failure.inference }
        }
        guard llama_process(self.context, LLAMA_PROCESS_TYPE_ENCODE, self.batch) == 0,
              let vector = llama_get_embeddings_seq(context, 0) else { throw Failure.inference }
        let values = Array(UnsafeBufferPointer(start: vector, count: 768))
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0, values.allSatisfy(\.isFinite) else { throw Failure.inference }
        return values.map { $0 / Float(norm) }
    }
}

do {
    guard CommandLine.arguments.count == 2 else { exit(64) }
    let encoder = try Encoder(path: CommandLine.arguments[1])
    while let line = readLine() {
        let response: Response
        do {
            guard line.utf8.count <= 32768 else { throw Failure.invalidInput }
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
            guard (1 ... 16).contains(request.texts.count) else { throw Failure.invalidInput }
            response = try Response(embeddings: request.texts.map(encoder.embed))
        } catch { response = Response(error: EINVAL) }
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response) + Data([10]))
    }
} catch { exit(1) }
