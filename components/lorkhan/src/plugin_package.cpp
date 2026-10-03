#include "lorkhan/plugin_package.hpp"

#include "lorkhan/voice_capture.hpp"

#include <algorithm>
#include <array>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <system_error>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace lorkhan {
namespace {

namespace fs = std::filesystem;
using Outcome = PluginPackageSyncOutcome;
using Status = PluginPackageSyncStatus;

bool isLowerHex64(std::string_view value)
{
    return value.size() == 64 && std::all_of(value.begin(), value.end(),
        [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); });
}

bool isReasonToken(std::string_view value)
{
    return !value.empty() && value.size() <= 64 && value.front() >= 'a' && value.front() <= 'z'
        && std::all_of(value.begin(), value.end(),
            [](char c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'; });
}

Error packageError(std::string_view reason, ErrorCode code = ErrorCode::invalid_argument)
{
    return makeError(code, std::string(reason));
}

Error cancelledError()
{
    return makeError(ErrorCode::cancelled, "package sync cancelled");
}

fs::path utf8Path(std::string_view value)
{
    return fs::path(std::u8string(value.begin(), value.end()));
}

// Links and Windows reparse points (junctions, mount points) are never followed below a data root.
bool isLinkOrReparse(const fs::path& path, fs::file_status status)
{
    if (fs::is_symlink(status)) return true;
#ifdef _WIN32
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
#else
    static_cast<void>(path);
    return false;
#endif
}

bool strictlyContains(const fs::path& root, const fs::path& child)
{
    auto childPart = child.begin();
    for (const auto& rootPart : root) {
        if (childPart == child.end() || *childPart != rootPart) return false;
        ++childPart;
    }
    return childPart != child.end();
}

#ifdef _WIN32
// Hold the verified file against replacement, rename and writes throughout hashing/upload.
class PackageLease {
public:
    explicit PackageLease(const fs::path& path)
    {
        m_file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (m_file == INVALID_HANDLE_VALUE) return;
        std::array<wchar_t, 32768> name{};
        const DWORD size = GetFinalPathNameByHandleW(m_file, name.data(), static_cast<DWORD>(name.size()), FILE_NAME_NORMALIZED);
        if (size == 0 || size >= name.size()) return;
        std::wstring actual(name.data(), size);
        if (actual.starts_with(L"\\\\?\\")) actual.erase(0, 4);
        std::error_code error;
        m_valid = fs::canonical(actual, error) == path && !error;
    }
    ~PackageLease() { if (m_file != INVALID_HANDLE_VALUE) CloseHandle(m_file); }
    PackageLease(const PackageLease&) = delete;
    PackageLease& operator=(const PackageLease&) = delete;
    bool valid() const { return m_valid; }
private:
    HANDLE m_file{INVALID_HANDLE_VALUE};
    bool m_valid{};
};
#endif

bool pause(std::stop_token cancellation, std::chrono::milliseconds duration, const std::function<void()>& yield)
{
    std::mutex mutex;
    std::condition_variable_any condition;
    std::unique_lock lock(mutex);
    const auto deadline = std::chrono::steady_clock::now() + duration;
    do {
        if (yield) yield();
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
        if (remaining <= std::chrono::milliseconds::zero()) break;
        static_cast<void>(condition.wait_for(lock, cancellation, std::min(remaining, std::chrono::milliseconds(25)), [] { return false; }));
    } while (!cancellation.stop_requested());
    return !cancellation.stop_requested();
}

Result<std::string> hashFile(const fs::path& path, std::uint64_t bytes, std::stop_token cancellation, const std::function<void()>& yield)
{
    std::ifstream file(path, std::ios::binary);
    if (!file) return Result<std::string>::failure(packageError("package_unreadable"));
    Sha256Stream digest;
    std::vector<char> buffer(kPluginPackageChunkBytes);
    std::uint64_t total = 0;
    while (file) {
        if (yield) yield();
        if (cancellation.stop_requested()) return Result<std::string>::failure(cancelledError());
        file.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const auto count = static_cast<std::uint64_t>(file.gcount());
        total += count;
        if (total > bytes) return Result<std::string>::failure(packageError("package_changed"));
        digest.update(std::as_bytes(std::span(buffer.data(), static_cast<std::size_t>(count))));
    }
    if (!file.eof()) return Result<std::string>::failure(packageError("package_unreadable"));
    if (total != bytes) return Result<std::string>::failure(packageError("package_changed"));
    return Result<std::string>::success(digest.finishHex());
}

// A typed 429 is refused before the server applies anything, so the same step is safe to repeat.
template <class Call>
auto withRateLimit(Call call, std::stop_token cancellation, const PluginPackageSyncLimits& limits, const std::function<void()>& yield) -> decltype(call())
{
    for (std::uint32_t attempt = 0;; ++attempt) {
        if (yield) yield();
        if (cancellation.stop_requested()) return decltype(call())::failure(cancelledError());
        auto result = call();
        if (result || result.error().code != ErrorCode::rate_limited || attempt >= limits.rateLimitRetries)
            return result;
        const auto requested = std::chrono::milliseconds(result.error().retryAfterMs.value_or(500));
        if (!pause(cancellation, std::clamp(requested, std::chrono::milliseconds(1), limits.maximumRetryAfter), yield))
            return decltype(call())::failure(cancelledError());
    }
}

std::string jsonToken(std::string_view value)
{
    // Callers pass validated tokens only: identifiers, versions, UUIDs and lowercase hexadecimal.
    return "\"" + std::string(value) + "\"";
}

} // namespace

std::string pluginPackageRelativePath(std::string_view pluginId, std::string_view version)
{
    return "lorkhan-packages/" + std::string(pluginId) + "/" + std::string(pluginId) + "-" + std::string(version)
        + ".dwpkg";
}

Result<ResolvedPluginPackage> resolvePluginPackage(
    const std::vector<std::string>& dataRoots, std::string_view pluginId, std::string_view version)
{
    using R = Result<ResolvedPluginPackage>;
    if (!isValidPluginId(pluginId) || !isValidPluginVersion(version))
        return R::failure(packageError("package_identity_invalid"));
    if (dataRoots.empty() || dataRoots.size() > kMaxPluginPackageRoots)
        return R::failure(packageError("package_roots_invalid"));
    const std::string fileName = std::string(pluginId) + "-" + std::string(version) + ".dwpkg";
    const std::array<fs::path, 3> components{fs::path("lorkhan-packages"), utf8Path(pluginId), utf8Path(fileName)};
    for (auto configured = dataRoots.rbegin(); configured != dataRoots.rend(); ++configured) {
        const fs::path rootPath = utf8Path(*configured);
        if (configured->empty() || !rootPath.is_absolute())
            return R::failure(packageError("package_roots_invalid"));
        std::error_code error;
        const fs::path root = fs::canonical(rootPath, error);
        if (error || !fs::is_directory(root, error) || error)
            continue; // An absent configured root contributes nothing, as in the VFS.
        fs::path current = root;
        bool absent = false;
        for (std::size_t index = 0; index < components.size(); ++index) {
            current /= components[index];
            const auto status = fs::symlink_status(current, error);
            if (status.type() == fs::file_type::not_found) {
                absent = true;
                break;
            }
            if (error) return R::failure(packageError("package_unreadable"));
            if (isLinkOrReparse(current, status)) return R::failure(packageError("package_link_rejected"));
            const bool file = index + 1 == components.size();
            if (file ? !fs::is_regular_file(status) : !fs::is_directory(status))
                return R::failure(packageError("package_not_regular"));
        }
        if (absent) continue;
        const fs::path resolved = fs::canonical(current, error);
        if (error || resolved != current || !strictlyContains(root, resolved))
            return R::failure(packageError("package_path_unsafe"));
        const auto bytes = fs::file_size(resolved, error);
        if (error) return R::failure(packageError("package_unreadable"));
        if (bytes > kMaxPluginPackageBytes) return R::failure(packageError("package_too_large"));
        if (bytes < kMinPluginPackageBytes) return R::failure(packageError("package_archive_invalid"));
        return R::success({resolved, static_cast<std::uint64_t>(bytes)});
    }
    return R::failure(packageError("package_not_found"));
}

std::string pluginPackageProbeBody(std::string_view pluginId, std::string_view version, std::string_view sha256)
{
    return "{\"plugin_id\":" + jsonToken(pluginId) + ",\"sha256\":" + jsonToken(sha256) + ",\"version\":" + jsonToken(version) + "}";
}

std::string pluginPackageUploadBody(
    std::string_view pluginId, std::string_view version, std::uint64_t size, std::string_view sha256)
{
    return "{\"plugin_id\":" + jsonToken(pluginId) + ",\"sha256\":" + jsonToken(sha256) + ",\"size\":" + std::to_string(size)
        + ",\"version\":" + jsonToken(version) + "}";
}

std::string pluginPackageSubmitBody(const RequestId& request, std::string_view uploadId)
{
    return "{\"request_id\":" + jsonToken(request.value()) + ",\"upload_id\":" + jsonToken(uploadId) + "}";
}

std::string_view pluginPackageSyncStatusName(PluginPackageSyncStatus status)
{
    switch (status) {
        case Status::current: return "current";
        case Status::installed: return "installed";
        case Status::updated: return "updated";
        case Status::newer_installed: return "newer_installed";
        case Status::conflict: return "conflict";
        case Status::pending: return "pending";
        case Status::missing: return "missing";
        case Status::failed: return "failed";
    }
    return "failed";
}

Result<void> validatePluginPackageSyncRequest(
    const PluginPackageSyncRequest& sync, const RequestId& request, const SessionId& session, Generation generation)
{
    const auto invalid = [](std::string message) {
        return Result<void>::failure(makeError(ErrorCode::invalid_argument, std::move(message)));
    };
    if (!isCanonicalUuid(request.value()) || !isCanonicalUuid(session.value()) || sync.correlation.request != request
        || sync.correlation.session != session || sync.correlation.generation != generation)
        return invalid("plugin package correlation is inconsistent");
    if (!isValidPluginId(sync.pluginId) || !isValidPluginVersion(sync.version) || !isLowerHex64(sync.manifestSha256))
        return invalid("plugin package identity is outside the closed contract");
    if (sync.dataRoots.empty() || sync.dataRoots.size() > kMaxPluginPackageRoots)
        return invalid("plugin package data roots are outside the bound");
    for (const auto& root : sync.dataRoots) {
        if (root.empty() || root.size() > kMaxPluginPackageRootBytes || root.find('\0') != std::string::npos
            || !isValidUtf8(root) || !utf8Path(root).is_absolute())
            return invalid("plugin package data root must be an absolute UTF-8 path");
    }
    return Result<void>::success();
}

Result<PluginPackageSyncOutcome> runPluginPackageSync(const PluginPackageSyncRequest& sync,
    const RequestId& request, IPluginPackageWire& wire, std::stop_token cancellation,
    const PluginPackageSyncLimits& limits, const std::function<void()>& yield)
{
    using R = Result<Outcome>;
    Outcome outcome{sync.pluginId, sync.version, Status::failed, {}, std::nullopt, std::nullopt, 0};
    const auto finish = [&outcome](Status status, std::string reason) {
        outcome.status = status;
        outcome.reasonCode = std::move(reason);
        return R::success(outcome);
    };
    // Typed server refusals are package outcomes; socket faults and malformed replies stay failures.
    const auto refused = [&finish](const Error& error) {
        return error.correlationId && isReasonToken(error.message) ? finish(Status::failed, error.message)
                                                                   : R::failure(error);
    };
    const auto mismatch = [](const char* message) { return R::failure(makeError(ErrorCode::transport_failure, message)); };
    auto valid = validatePluginPackageSyncRequest(sync, request, sync.correlation.session, sync.correlation.generation);
    if (!valid) return R::failure(valid.error());
    if (cancellation.stop_requested()) return R::failure(cancelledError());

    auto resolved = resolvePluginPackage(sync.dataRoots, sync.pluginId, sync.version);
    if (!resolved)
        return finish(resolved.error().message == "package_not_found" ? Status::missing : Status::failed,
            resolved.error().message);
    const auto& package = resolved.value();
#ifdef _WIN32
    PackageLease lease(package.path);
    if (!lease.valid()) return finish(Status::failed, "package_path_unsafe");
#endif
    // Recheck containment after opening and again before upload; the held Windows file is immutable.
    const auto unchangedPath = [&] {
        auto current = resolvePluginPackage(sync.dataRoots, sync.pluginId, sync.version);
        return current && current.value().path == package.path && current.value().bytes == package.bytes;
    };
    if (!unchangedPath()) return finish(Status::failed, "package_changed");
    auto hashed = hashFile(package.path, package.bytes, cancellation, yield);
    if (!hashed)
        return hashed.error().code == ErrorCode::cancelled ? R::failure(hashed.error())
                                                           : finish(Status::failed, hashed.error().message);
    const std::string sha256 = hashed.value();

    const auto probe = [&] {
        return withRateLimit([&] { return wire.probe(sync.pluginId, sync.version, sha256); }, cancellation, limits, yield);
    };
    PluginPackageProbe probed;
    for (const auto deadline = std::chrono::steady_clock::now() + limits.pendingWait;;) {
        auto current = probe();
        if (!current) return refused(current.error());
        if (current.value().pluginId != sync.pluginId) return mismatch("package probe names another plugin");
        probed = std::move(current).value();
        if (!probed.pending) break;
        if (std::chrono::steady_clock::now() >= deadline) return finish(Status::pending, "package_operation_pending");
        if (!pause(cancellation, limits.pollInterval, yield)) return R::failure(cancelledError());
    }
    if (probed.installed && probed.installed->state == "installed") {
        outcome.installedVersion = probed.installed->version;
        outcome.enabled = probed.installed->enabled;
    }
    switch (probed.action) {
        case PluginPackageProbeAction::current:
            if (probed.installed->manifestSha256 != sync.manifestSha256)
                return finish(Status::failed, "package_manifest_mismatch");
            return finish(Status::current, "package_current");
        case PluginPackageProbeAction::older: return finish(Status::newer_installed, "package_newer_installed");
        case PluginPackageProbeAction::conflict: return finish(Status::conflict, "package_version_conflict");
        case PluginPackageProbeAction::install:
        case PluginPackageProbeAction::update: break;
    }
    const bool update = probed.action == PluginPackageProbeAction::update;

    auto started = withRateLimit([&] { return wire.startUpload(sync.pluginId, sync.version, package.bytes, sha256); },
        cancellation, limits, yield);
    if (!started) return refused(started.error());
    const std::string uploadId = started.value().uploadId;
    const std::uint64_t chunkBytes = started.value().chunkBytes;
    if (!unchangedPath()) return finish(Status::failed, "package_changed");
    std::ifstream file(package.path, std::ios::binary);
    if (!file) return finish(Status::failed, "package_unreadable");
    Sha256Stream verify;
    std::vector<std::byte> buffer(static_cast<std::size_t>(chunkBytes));
    for (std::uint64_t sent = 0, index = 0; sent < package.bytes; ++index) {
        if (cancellation.stop_requested()) return R::failure(cancelledError());
        const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(chunkBytes, package.bytes - sent));
        file.read(reinterpret_cast<char*>(buffer.data()), static_cast<std::streamsize>(count));
        if (static_cast<std::size_t>(file.gcount()) != count) return finish(Status::failed, "package_changed");
        const std::span<const std::byte> chunk(buffer.data(), count);
        verify.update(chunk);
        auto put = withRateLimit([&] { return wire.putChunk(uploadId, index, chunk); }, cancellation, limits, yield);
        if (!put) return refused(put.error());
        const bool last = sent + count == package.bytes;
        if (put.value().uploadId != uploadId || put.value().nextIndex != index + 1
            || put.value().received != sent + count || put.value().complete != last)
            return mismatch("package upload progress mismatch");
        sent += count;
        outcome.uploadedBytes = sent;
    }
    if (verify.finishHex() != sha256) return finish(Status::failed, "package_changed");

    auto submitted = withRateLimit([&] { return wire.submit(update, request, uploadId); }, cancellation, limits, yield);
    if (!submitted) {
        if (submitted.error().correlationId && submitted.error().message == "package_operation_pending")
            return finish(Status::pending, "package_operation_pending");
        return refused(submitted.error());
    }
    PluginPackageOperation operation = std::move(submitted).value();
    const std::string operationId = operation.operationId;
    const auto sameOperation = [&](const PluginPackageOperation& value) {
        return value.operationId == operationId && value.pluginId == sync.pluginId && value.version == sync.version
            && value.archiveSha256 == sha256 && value.update == update;
    };
    if (!sameOperation(operation)) return mismatch("package operation does not match the upload");
    auto interval = limits.pollInterval;
    for (const auto deadline = std::chrono::steady_clock::now() + limits.operationWait;
         operation.state == PluginPackageOperationState::queued;) {
        if (std::chrono::steady_clock::now() >= deadline) return finish(Status::pending, "package_operation_queued");
        if (!pause(cancellation, interval, yield)) return R::failure(cancelledError());
        interval = std::min(interval * 2, limits.maximumPollInterval);
        auto polled = withRateLimit([&] { return wire.operation(operationId); }, cancellation, limits, yield);
        if (!polled) return refused(polled.error());
        if (!sameOperation(polled.value())) return mismatch("package operation changed identity");
        operation = std::move(polled).value();
    }
    if (operation.state == PluginPackageOperationState::failed)
        return finish(Status::failed, *operation.errorCode);

    // The operation alone does not report policy; read back the installed row it produced.
    auto confirmed = probe();
    if (!confirmed) return refused(confirmed.error());
    const auto& installed = confirmed.value().installed;
    if (confirmed.value().pluginId != sync.pluginId || confirmed.value().action != PluginPackageProbeAction::current
        || !installed || installed->archiveSha256 != sha256)
        return finish(Status::failed, "package_install_unconfirmed");
    outcome.installedVersion = installed->version;
    outcome.enabled = installed->enabled;
    if (installed->manifestSha256 != sync.manifestSha256) return finish(Status::failed, "package_manifest_mismatch");
    return finish(update ? Status::updated : Status::installed, update ? "package_updated" : "package_installed");
}

std::string serializePluginPackageSyncOutcome(const PluginPackageSyncOutcome& outcome)
{
    const auto optionalText = [](const std::optional<std::string>& value) {
        return value && isValidPluginVersion(*value) ? jsonToken(*value) : std::string("null");
    };
    return "{\"enabled\":" + std::string(outcome.enabled ? (*outcome.enabled ? "true" : "false") : "null")
        + ",\"installed_version\":" + optionalText(outcome.installedVersion)
        + ",\"plugin_id\":" + jsonToken(isValidPluginId(outcome.pluginId) ? outcome.pluginId : std::string())
        + ",\"reason_code\":" + jsonToken(isReasonToken(outcome.reasonCode) ? outcome.reasonCode : "package_sync_failed")
        + ",\"status\":" + jsonToken(pluginPackageSyncStatusName(outcome.status))
        + ",\"uploaded_bytes\":" + std::to_string(outcome.uploadedBytes)
        + ",\"version\":" + jsonToken(isValidPluginVersion(outcome.version) ? outcome.version : std::string()) + "}";
}

} // namespace lorkhan
