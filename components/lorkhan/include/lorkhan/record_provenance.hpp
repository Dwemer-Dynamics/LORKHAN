#pragma once

#include <algorithm>
#include <string>
#include <vector>

namespace lorkhan
{
    // Captures contributors in content-load order; truncation never claims a complete chain.
    struct RecordProvenance
    {
        static constexpr std::size_t maxFiles = 128;
        std::vector<std::string> files;
        std::string winningFile;
        bool complete = true;

        void observe(const std::string& file)
        {
            if (file.empty() || file.size() > 256 || file.find_first_of("/\\:") != std::string::npos
                || std::any_of(file.begin(), file.end(), [](unsigned char c) { return c < 32 || c == 127; }))
            {
                complete = false;
                winningFile.clear();
                return;
            }
            winningFile = file;
            if (std::find(files.begin(), files.end(), file) != files.end()) return;
            if (files.size() < maxFiles) files.push_back(file);
            else complete = false;
        }
    };
}
