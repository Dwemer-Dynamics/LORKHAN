#pragma once
#include <functional>

#include "lorkhan/protocol_response.hpp"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <stop_token>
#include <string>
#include <string_view>
#include <vector>

namespace lorkhan {

inline constexpr std::size_t kMinPluginPackageBytes = 22U;
inline constexpr std::size_t kPluginPackageChunkBytes = 1024U * 1024U;

[[nodiscard]] bool isValidPluginId(std::string_view value);
[[nodiscard]] bool isValidPluginVersion(std::string_view value);

// The only file a sync may read: <data root>/lorkhan-packages/<plugin_id>/<plugin_id>-<version>.dwpkg.
[[nodiscard]] std::string pluginPackageRelativePath(std::string_view pluginId, std::string_view version);

struct ResolvedPluginPackage {
    std::filesystem::path path;
    std::uint64_t bytes{};
};

// Highest-priority (last) data root wins. Every component below the root must be a real directory or
// regular file: links and reparse points fail closed. Errors carry a closed reason code as the message.
[[nodiscard]] Result<ResolvedPluginPackage> resolvePluginPackage(
    const std::vector<std::string>& dataRoots, std::string_view pluginId, std::string_view version);

// Server package lifecycle (LorkhanServer /plugin-packages, Stage 2). Responses never contain paths.
struct PluginPackageInfo {
    std::string pluginId;
    std::string version;
    std::string state;
    bool enabled{};
    std::string archiveSha256;
    std::string manifestSha256;
};
enum class PluginPackageProbeAction { install, update, current, older, conflict };
struct PluginPackageProbe {
    std::string pluginId;
    PluginPackageProbeAction action{PluginPackageProbeAction::install};
    bool pending{};
    std::optional<PluginPackageInfo> installed;
};
struct PluginPackageUpload {
    std::string uploadId;
    std::uint64_t nextIndex{};
    std::uint64_t received{};
    std::uint64_t chunkBytes{};
    bool complete{};
};
enum class PluginPackageOperationState { queued, succeeded, failed };
struct PluginPackageOperation {
    std::string operationId;
    std::string pluginId;
    bool update{};
    std::string version;
    std::string archiveSha256;
    PluginPackageOperationState state{PluginPackageOperationState::queued};
    std::optional<std::string> errorCode;
};

[[nodiscard]] Result<PluginPackageProbe> parsePluginPackageProbeResponse(
    std::string_view body, const Headers& headers);
// startUpload responses carry chunk_bytes and no received count; chunk responses the reverse.
[[nodiscard]] Result<PluginPackageUpload> parsePluginPackageUploadResponse(
    std::string_view body, const Headers& headers, bool started);
[[nodiscard]] Result<PluginPackageOperation> parsePluginPackageOperationResponse(
    std::string_view body, const Headers& headers);
// lorkhan.error.v1 that may also carry the closed package_* codes; wireCode keeps the server code.
[[nodiscard]] Result<ProtocolError> parsePluginPackageErrorResponse(
    std::string_view body, const Headers& headers);

[[nodiscard]] std::string pluginPackageProbeBody(
    std::string_view pluginId, std::string_view version, std::string_view sha256);
[[nodiscard]] std::string pluginPackageUploadBody(
    std::string_view pluginId, std::string_view version, std::uint64_t size, std::string_view sha256);
[[nodiscard]] std::string pluginPackageSubmitBody(const RequestId& request, std::string_view uploadId);

// One typed exchange per server step. Implementations sign each request with the paired request MAC,
// send X-LORKHAN-Request-Id equal to the sync request and return typed server errors with a
// correlationId and the wire code as the message.
class IPluginPackageWire {
public:
    virtual ~IPluginPackageWire() = default;
    virtual Result<PluginPackageProbe> probe(
        std::string_view pluginId, std::string_view version, std::string_view sha256) = 0;
    virtual Result<PluginPackageUpload> startUpload(
        std::string_view pluginId, std::string_view version, std::uint64_t size, std::string_view sha256) = 0;
    virtual Result<PluginPackageUpload> putChunk(
        std::string_view uploadId, std::uint64_t index, std::span<const std::byte> bytes) = 0;
    // Idempotency-Key and body request_id are both the sync request ID.
    virtual Result<PluginPackageOperation> submit(bool update, const RequestId& request, std::string_view uploadId) = 0;
    virtual Result<PluginPackageOperation> operation(std::string_view operationId) = 0;
};

struct PluginPackageSyncLimits {
    std::chrono::milliseconds pendingWait{5000};
    std::chrono::milliseconds operationWait{15000};
    std::chrono::milliseconds pollInterval{250};
    std::chrono::milliseconds maximumPollInterval{1000};
    std::chrono::milliseconds maximumRetryAfter{2000};
    std::uint32_t rateLimitRetries{8};
};

enum class PluginPackageSyncStatus { current, installed, updated, newer_installed, conflict, pending, missing, failed };

struct PluginPackageSyncOutcome {
    std::string pluginId;
    std::string version;
    PluginPackageSyncStatus status{PluginPackageSyncStatus::failed};
    std::string reasonCode;
    std::optional<bool> enabled;
    std::optional<std::string> installedVersion;
    std::uint64_t uploadedBytes{};
};

[[nodiscard]] std::string_view pluginPackageSyncStatusName(PluginPackageSyncStatus status);

// Validate the main-thread DTO for exactly this request without touching the filesystem.
[[nodiscard]] Result<void> validatePluginPackageSyncRequest(
    const PluginPackageSyncRequest& sync, const RequestId& request, const SessionId& session, Generation generation);

// Runs on the transport worker: resolve, hash, probe, then upload, install/update and poll only when the
// server needs this package. Package and server decisions are outcomes; transport faults and
// cancellation are failures. A failed or pending server operation leaves the prior installed version.
[[nodiscard]] Result<PluginPackageSyncOutcome> runPluginPackageSync(const PluginPackageSyncRequest& sync,
    const RequestId& request, IPluginPackageWire& wire, std::stop_token cancellation,
    const PluginPackageSyncLimits& limits = {}, const std::function<void()>& yield = {});

// Compact JSON for the inbound result: plugin_id, version, status, reason_code, enabled,
// installed_version and uploaded_bytes.
[[nodiscard]] std::string serializePluginPackageSyncOutcome(const PluginPackageSyncOutcome& outcome);

} // namespace lorkhan
