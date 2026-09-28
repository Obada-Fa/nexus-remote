#include "whisper.h"
#include "json.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using json = nlohmann::json;
static std::atomic<bool> abort_job{false};
static std::mutex queue_mutex;
static std::condition_variable queue_ready;
static std::deque<json> queue;
static bool input_closed = false;

static bool read_frame(json & result) {
    uint8_t header[4];
    if (!std::cin.read(reinterpret_cast<char *>(header), 4)) return false;
    const uint32_t size = uint32_t(header[0]) | uint32_t(header[1]) << 8 |
                          uint32_t(header[2]) << 16 | uint32_t(header[3]) << 24;
    if (size == 0 || size > 1024 * 1024) return false;
    std::string payload(size, '\0');
    if (!std::cin.read(payload.data(), size)) return false;
    try { result = json::parse(payload); return true; }
    catch (...) { return false; }
}
static void write_frame(const json & value) {
    const std::string payload = value.dump();
    const uint32_t size = static_cast<uint32_t>(payload.size());
    uint8_t header[4] = {uint8_t(size), uint8_t(size >> 8), uint8_t(size >> 16), uint8_t(size >> 24)};
    std::cout.write(reinterpret_cast<char *>(header), 4);
    std::cout.write(payload.data(), payload.size());
    std::cout.flush();
}
static void read_commands() {
    json command;
    while (read_frame(command)) {
        if (command.value("method", "") == "cancel") {
            abort_job = true;
        } else {
            std::lock_guard<std::mutex> lock(queue_mutex);
            queue.push_back(std::move(command));
            queue_ready.notify_one();
        }
    }
    std::lock_guard<std::mutex> lock(queue_mutex);
    input_closed = true;
    queue_ready.notify_one();
}
static uint16_t le16(const uint8_t * p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
static uint32_t le32(const uint8_t * p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
static std::vector<float> read_wav(const std::string & path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("audio_unavailable");
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
    if (bytes.size() < 44 || bytes.size() > 10 * 1024 * 1024 ||
        std::string(reinterpret_cast<char *>(bytes.data()), 4) != "RIFF" ||
        std::string(reinterpret_cast<char *>(bytes.data() + 8), 4) != "WAVE")
        throw std::runtime_error("invalid_wav");
    bool format_found = false;
    size_t audio_offset = 0, audio_size = 0;
    for (size_t offset = 12; offset + 8 <= bytes.size();) {
        const uint32_t size = le32(bytes.data() + offset + 4);
        const size_t data = offset + 8;
        if (size > bytes.size() - data) throw std::runtime_error("invalid_wav");
        std::string chunk(reinterpret_cast<char *>(bytes.data() + offset), 4);
        if (chunk == "fmt ") {
            if (size < 16 || le16(bytes.data() + data) != 1 ||
                le16(bytes.data() + data + 2) != 1 ||
                le32(bytes.data() + data + 4) != 16000 ||
                le16(bytes.data() + data + 14) != 16)
                throw std::runtime_error("unsupported_audio_format");
            format_found = true;
        }
        if (chunk == "data") { audio_offset = data; audio_size = size; }
        offset = data + size + (size & 1);
    }
    if (!format_found || audio_size == 0 || (audio_size & 1) != 0 ||
        audio_size > 16000ULL * 2 * 300)
        throw std::runtime_error("invalid_wav");
    std::vector<float> pcm(audio_size / 2);
    for (size_t i = 0; i < pcm.size(); ++i)
        pcm[i] = static_cast<int16_t>(le16(bytes.data() + audio_offset + i * 2)) / 32768.0f;
    return pcm;
}
static bool abort_callback(void *) { return abort_job.load(); }
static json transcribe(whisper_context * context, const json & command) {
    const auto audio = read_wav(command.at("path").get<std::string>());
    // Reject digital silence; quiet real speech is still passed to the model.
    double energy = 0;
    for (float sample : audio) energy += double(sample) * sample;
    if (energy / audio.size() < 1e-8) return {{"status","no_speech"},{"text",""},{"segments",json::array()}};
    auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.translate = false;
    params.no_context = true;
    params.n_threads = std::max(1, std::min(8, int(std::thread::hardware_concurrency() / 2)));
    const std::string language = command.value("language", "auto");
    if (language != "auto" && language != "en" && language != "nl")
        throw std::runtime_error("invalid_language");
    params.language = language.c_str();
    params.abort_callback = abort_callback;
    abort_job = false;
    if (whisper_full(context, params, audio.data(), int(audio.size())) != 0) {
        if (abort_job) return {{"status","cancelled"}};
        throw std::runtime_error("inference_failed");
    }
    json segments = json::array();
    std::string text;
    for (int i = 0; i < whisper_full_n_segments(context); ++i) {
        std::string segment = whisper_full_get_segment_text(context, i);
        text += segment;
        segments.push_back({{"start_ms",whisper_full_get_segment_t0(context,i)*10},
                            {"end_ms",whisper_full_get_segment_t1(context,i)*10},
                            {"text",segment}});
    }
    return {{"status",text.empty() ? "no_speech" : "completed"},{"text",text},{"segments",segments}};
}
int main() {
    std::thread reader(read_commands);
    reader.detach();
    whisper_context * context = nullptr;
    while (true) {
        json command;
        {
            std::unique_lock<std::mutex> lock(queue_mutex);
            queue_ready.wait(lock, [] { return !queue.empty() || input_closed; });
            if (queue.empty()) break;
            command = std::move(queue.front());
            queue.pop_front();
        }
        const std::string id = command.value("id", "");
        const std::string method = command.value("method", "");
        try {
            if (method == "load") {
                if (context) whisper_free(context);
                auto options = whisper_context_default_params();
                options.use_gpu = false;
                context = whisper_init_from_file_with_params(command.at("path").get<std::string>().c_str(),options);
                if (!context) throw std::runtime_error("model_load_failed");
                write_frame({{"id",id},{"result",{{"status","loaded"}}}});
            } else if (method == "transcribe") {
                if (!context) throw std::runtime_error("model_missing");
                write_frame({{"id",id},{"result",transcribe(context,command)}});
            } else if (method == "unload") {
                if (context) whisper_free(context);
                context = nullptr;
                write_frame({{"id",id},{"result",{{"status","unloaded"}}}});
            } else if (method == "shutdown") {
                write_frame({{"id",id},{"result",{{"status","stopped"}}}});
                break;
            } else {
                throw std::runtime_error("unknown_method");
            }
        } catch (const std::exception & error) {
            write_frame({{"id",id},{"error",{{"code",error.what()}}}});
        }
    }
    if (context) whisper_free(context);
}
