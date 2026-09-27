#pragma once
#include <filesystem>
#include <stdexcept>
#include <string_view>

namespace lorkhan {
// Explicit profiles win; otherwise resolve pairing beside the installed engine, never the working directory.
inline std::filesystem::path clientConfigPath(std::string_view overridePath,
    const std::filesystem::path& executableDirectory)
{
    if (!overridePath.empty()) return std::filesystem::u8path(overridePath);
    if (!executableDirectory.empty()) {
        const auto installed = executableDirectory.parent_path() / "Config" / "lorkhan-client.conf";
        if (std::filesystem::is_regular_file(installed)) return installed;
        const auto portable = executableDirectory / "lorkhan-client.conf";
        if (std::filesystem::is_regular_file(portable)) return portable;
    }
    throw std::runtime_error("LORKHAN pairing config not found beside this installation; run LORKHAN setup");
}
}
