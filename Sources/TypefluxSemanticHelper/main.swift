import CLlama
import Foundation

// Private disposable helper. stdout contains only line-delimited JSON; inputs are never logged.
struct Media: Decodable { var kind: String; var path: String }
struct Request: Decodable { var texts: [String]?; var media: Media? }
struct Response: Encodable { let entries: [String] = []; var embeddings: [[Float]]?; var error: Int32? }
enum Failure: Error { case invalidInput, inference }

final class Encoder {
    let model: OpaquePointer
    let context: OpaquePointer
    let batch: OpaquePointer
    var media: OpaquePointer?

    init(path: String, projector: String? = nil) throws {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
        mtmd_helper_log_set({ _, _, _ in }, nil)
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
        guard llama_model_n_embd_out(model) == 768 else {
            llama_free(context); llama_model_free(model); throw Failure.inference
        }
        guard let batch = llama_batch_ext_init(context) else {
            llama_free(context); llama_model_free(model); throw Failure.inference
        }
        var media: OpaquePointer?
        if let projector {
            var options = mtmd_context_params_default()
            options.use_gpu = true; options.print_timings = false; options.warmup = false
            options.image_min_tokens = 1; options.image_max_tokens = 280
            media = mtmd_init_from_file(projector, model, options)
            guard media != nil else {
                llama_batch_ext_free(batch); llama_free(context); llama_model_free(model); throw Failure.inference
            }
        }
        self.model = model; self.context = context; self.batch = batch; self.media = media
    }

    deinit {
        if let media { mtmd_free(media) }
        llama_batch_ext_free(batch); llama_free(context); llama_model_free(model)
        llama_backend_free()
    }

    // Keep bitmap, chunks and batch ownership in one inference scope.
    // swiftlint:disable:next cyclomatic_complexity
    func embedMedia(_ input: Media) throws -> [Float] {
        guard let media, ["image", "audio"].contains(input.kind), input.path.hasPrefix("/")
        else { throw Failure.invalidInput }
        let loaded = mtmd_helper_bitmap_init_from_file(media, input.path, false, mtmd_helper_init_opt_default())
        if let video = loaded.video_ctx {
            if let bitmap = loaded.bitmap { mtmd_bitmap_free(bitmap) }
            mtmd_helper_video_free(video); throw Failure.invalidInput
        }
        guard let bitmap = loaded.bitmap else { throw Failure.invalidInput }
        defer { mtmd_bitmap_free(bitmap) }
        guard mtmd_bitmap_is_audio(bitmap) == (input.kind == "audio") else { throw Failure.invalidInput }
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        var bitmaps: [OpaquePointer?] = [bitmap]
        let result = String(cString: mtmd_default_marker()).withCString { marker in
            var text = mtmd_input_text(text: marker, text_len: strlen(marker), add_special: true, parse_special: true)
            return mtmd_tokenize(media, chunks, &text, &bitmaps, 1)
        }
        guard result == 0 else { throw Failure.inference }
        llama_batch_ext_clear(batch)
        defer { llama_batch_ext_clear(batch) }
        var position = 0
        let rowSize = Int(llama_model_n_embd_inp(model))
        for index in 0 ..< mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, index)
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var count = 0
                guard let tokens = mtmd_input_chunk_get_tokens_text(chunk, &count) else { continue }
                for tokenIndex in 0 ..< count {
                    try place(llama_batch_ext_add_token(batch, 0, tokens[tokenIndex]), position: position)
                    position += 1
                }
            } else {
                guard mtmd_encode_chunk(media, chunk) == 0, let rows = mtmd_get_output_embd(media)
                else { throw Failure.inference }
                for row in 0 ..< mtmd_input_chunk_get_n_tokens(chunk) {
                    let value = llama_embd(data: rows + row * rowSize, n_rows: 1, n_embd: rowSize)
                    try place(llama_batch_ext_add_embd(batch, 0, value), position: position); position += 1
                }
            }
        }
        return try run()
    }

    private func place(_ row: Int32, position: Int) throws {
        var coordinates: [llama_pos] = [llama_pos(position), 0, 0, 0]
        guard position < 2048, row >= 0, llama_batch_ext_set_pos(batch, row, &coordinates),
              llama_batch_ext_set_output_embd(batch, row, true) else { throw Failure.inference }
    }

    private func run() throws -> [Float] {
        guard llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch) == 0,
              let vector = llama_get_embeddings_seq(context, 0) else { throw Failure.inference }
        let values = Array(UnsafeBufferPointer(start: vector, count: 768))
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0, values.allSatisfy(\.isFinite) else { throw Failure.inference }
        return values.map { $0 / Float(norm) }
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
        return try run()
    }
}

do {
    guard (2 ... 3).contains(CommandLine.arguments.count) else { exit(64) }
    let encoder = try Encoder(path: CommandLine.arguments[1],
                              projector: CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : nil)
    while let line = readLine() {
        let response: Response
        do {
            guard line.utf8.count <= 32768 else { throw Failure.invalidInput }
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
            if let media = request.media {
                response = try Response(embeddings: [encoder.embedMedia(media)])
            } else {
                guard let texts = request.texts, (1 ... 16).contains(texts.count) else { throw Failure.invalidInput }
                response = try Response(embeddings: texts.map(encoder.embed))
            }
        } catch Failure.inference { response = Response(error: EIO) } catch { response = Response(error: EINVAL) }
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response) + Data([10]))
    }
} catch { exit(1) }
