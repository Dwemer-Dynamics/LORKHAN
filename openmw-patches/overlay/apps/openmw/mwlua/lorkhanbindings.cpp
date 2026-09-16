#include "lorkhanbindings.hpp"

#include <apps/openmw/mwlua/context.hpp>

#include <lorkhan/beast_transport.hpp>
#include <lorkhan/bridge_service.hpp>
#include <lorkhan/protocol_response.hpp>
#include <lorkhan/validation.hpp>
#include <lorkhan/playback.hpp>
#include <lorkhan/session_identity.hpp>
#include <lorkhan/voice_capture.hpp>
#include <components/lua/configuration.hpp>
#include <components/lua/scriptscontainer.hpp>
#include <components/files/constrainedfilestream.hpp>
#include <components/files/conversion.hpp>
#include <components/settings/values.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/mechanicsmanager.hpp"
#include "../mwbase/luamanager.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwmechanics/aisequence.hpp"
#include "../mwmechanics/creaturestats.hpp"
#include "../mwmechanics/spells.hpp"
#include <components/esm3/loadspel.hpp>
#include "../mwworld/class.hpp"
#include "../mwworld/esmstore.hpp"
#include "../mwworld/worldmodel.hpp"
#include "../mwworld/actiontake.hpp"
#include "../mwworld/actiontalk.hpp"
#include "../mwworld/actionteleport.hpp"
#include <cctype>
#include "../mwbase/windowmanager.hpp"
#include "../mwgui/dialogue.hpp"
#include "../mwworld/cell.hpp"
#include "../mwbase/world.hpp"
#include "../mwworld/containerstore.hpp"
#include "../mwworld/manualref.hpp"
#include <components/esm3/loadbook.hpp>
#include <components/esm3/loadcrea.hpp>

#include "luamanagerimp.hpp"
#include "objectvariant.hpp"

#include <sol/sol.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <ctime>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <limits>
#include <mutex>
#include <optional>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace MWLua
{
    namespace
    {
        using namespace std::chrono_literals;

        struct ClientConfig
        {
            lorkhan::BaseUrl baseUrl;
            lorkhan::PairingToken::Secret key{};
            lorkhan::InstallationId installation;
            lorkhan::ProfileId profile;
            lorkhan::PlaythroughId playthrough;
            std::string fingerprint;
            std::string platform;
            std::filesystem::path cacheRoot;
            std::string vfsPrefix;
        };

        std::string trim(std::string value)
        {
            const auto begin = value.find_first_not_of(" \t\r\n");
            if (begin == std::string::npos)
                return {};
            const auto end = value.find_last_not_of(" \t\r\n");
            return value.substr(begin, end - begin + 1);
        }

        int base64UrlValue(char value)
        {
            if (value >= 'A' && value <= 'Z') return value - 'A';
            if (value >= 'a' && value <= 'z') return value - 'a' + 26;
            if (value >= '0' && value <= '9') return value - '0' + 52;
            if (value == '-') return 62;
            if (value == '_') return 63;
            return -1;
        }

        lorkhan::PairingToken::Secret decodePairingKey(const std::string& encoded)
        {
            if (encoded.size() != 43)
                throw std::runtime_error("pairing_key must be an unpadded 32-byte base64url value");
            lorkhan::PairingToken::Secret result{};
            std::uint32_t accumulator = 0;
            unsigned bits = 0;
            std::size_t output = 0;
            for (const char value : encoded)
            {
                const int digit = base64UrlValue(value);
                if (digit < 0)
                    throw std::runtime_error("pairing_key contains a non-base64url character");
                accumulator = (accumulator << 6U) | static_cast<unsigned>(digit);
                bits += 6U;
                if (bits >= 8U)
                {
                    bits -= 8U;
                    if (output >= result.size())
                        throw std::runtime_error("pairing_key is too long");
                    result[output++] = static_cast<std::byte>((accumulator >> bits) & 0xffU);
                }
            }
            if (output != result.size())
                throw std::runtime_error("pairing_key does not decode to 32 bytes");
            return result;
        }

        ClientConfig loadConfig()
        {
            const char* configPath = std::getenv("LORKHAN_CLIENT_CONFIG");
            if (configPath == nullptr || *configPath == '\0')
                throw std::runtime_error("LORKHAN_CLIENT_CONFIG is not set");
            std::ifstream stream(std::filesystem::u8path(configPath));
            if (!stream)
                throw std::runtime_error("LORKHAN client config could not be opened");
            std::map<std::string, std::string> values;
            std::string line;
            while (std::getline(stream, line))
            {
                line = trim(line);
                if (line.empty() || line.front() == '#')
                    continue;
                const auto equals = line.find('=');
                if (equals == std::string::npos)
                    throw std::runtime_error("LORKHAN client config contains a malformed line");
                const std::string key = trim(line.substr(0, equals));
                const std::string value = trim(line.substr(equals + 1));
                static const std::array known{ "base_url", "pairing_key", "installation_id", "profile_id",
                    "playthrough_id", "content_fingerprint", "platform", "media_cache_root", "media_vfs_prefix" };
                if (std::find(known.begin(), known.end(), key) == known.end() || value.empty() || values.contains(key))
                    throw std::runtime_error("LORKHAN client config contains an unknown, empty, or duplicate field");
                values.emplace(key, value);
            }
            const auto required = [&values](const std::string& key) -> const std::string& {
                const auto found = values.find(key);
                if (found == values.end())
                    throw std::runtime_error("LORKHAN client config is missing " + key);
                return found->second;
            };
            auto baseUrl = lorkhan::parseLoopbackBaseUrl(required("base_url"));
            if (!baseUrl)
                throw std::runtime_error(baseUrl.error().message);
            ClientConfig config{ std::move(baseUrl).value(), decodePairingKey(required("pairing_key")),
                lorkhan::InstallationId(required("installation_id")), lorkhan::ProfileId(required("profile_id")),
                lorkhan::PlaythroughId(required("playthrough_id")), required("content_fingerprint"),
                required("platform"), std::filesystem::u8path(required("media_cache_root")),
                required("media_vfs_prefix") };
            if (!lorkhan::isCanonicalUuid(config.installation.value()) || !lorkhan::isCanonicalUuid(config.profile.value())
                || !lorkhan::isCanonicalUuid(config.playthrough.value()))
                throw std::runtime_error("LORKHAN configured IDs must be canonical lowercase UUIDs");
            if (!config.fingerprint.starts_with("sha256:") || config.fingerprint.size() != 71)
                throw std::runtime_error("content_fingerprint must be sha256 followed by 64 lowercase hex digits");
            if (config.vfsPrefix.empty() || config.vfsPrefix.front() == '/' || config.vfsPrefix.find("..") != std::string::npos)
                throw std::runtime_error("media_vfs_prefix must be a relative VFS prefix");
            return config;
        }

        std::string uuid()
        {
            static std::mutex mutex;
            static std::mt19937_64 random(std::random_device{}());
            std::lock_guard lock(mutex);
            std::array<unsigned char, 16> bytes{};
            for (std::size_t offset = 0; offset < bytes.size(); offset += 8)
            {
                const std::uint64_t value = random();
                for (std::size_t index = 0; index < 8; ++index)
                    bytes[offset + index] = static_cast<unsigned char>(value >> (index * 8U));
            }
            bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0fU) | 0x40U);
            bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3fU) | 0x80U);
            std::ostringstream out;
            out << std::hex << std::setfill('0');
            for (std::size_t index = 0; index < bytes.size(); ++index)
            {
                out << std::setw(2) << static_cast<unsigned>(bytes[index]);
                if (index == 3 || index == 5 || index == 7 || index == 9)
                    out << '-';
            }
            return out.str();
        }

        std::string utcNow()
        {
            const std::time_t raw = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
            std::tm value{};
#ifdef _WIN32
            gmtime_s(&value, &raw);
#else
            gmtime_r(&raw, &value);
#endif
            std::ostringstream out;
            out << std::put_time(&value, "%Y-%m-%dT%H:%M:%SZ");
            return out.str();
        }

        // Seed each engine process above previous local sessions while retaining cheap increments
        // for save loads, interruptions, and other lifecycle invalidations inside that process.
        lorkhan::Generation processGeneration()
        {
            const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            if (elapsed < 0 || elapsed > 9007199254740991LL)
                throw std::runtime_error("system clock is outside the supported generation range");
            return lorkhan::Generation(static_cast<std::uint64_t>(elapsed));
        }

        std::chrono::system_clock::time_point parseUtc(const std::string& input)
        {
            std::tm value{};
            std::istringstream stream(input);
            stream >> std::get_time(&value, "%Y-%m-%dT%H:%M:%SZ");
            if (!stream || stream.peek() != std::char_traits<char>::eof())
                throw std::runtime_error("invalid UTC media expiry");
#ifdef _WIN32
            const std::time_t raw = _mkgmtime(&value);
#else
            const std::time_t raw = timegm(&value);
#endif
            if (raw < 0) throw std::runtime_error("invalid UTC media expiry");
            return std::chrono::system_clock::from_time_t(raw);
        }

        std::array<std::byte, 32> parseSha256(const std::string& input)
        {
            if (input.size() != 64) throw std::runtime_error("media SHA-256 must contain 64 hex digits");
            std::array<std::byte, 32> result{};
            const auto digit = [](char value) -> int {
                if (value >= '0' && value <= '9') return value - '0';
                if (value >= 'a' && value <= 'f') return value - 'a' + 10;
                return -1;
            };
            for (std::size_t index = 0; index < result.size(); ++index)
            {
                const int high = digit(input[index * 2]); const int low = digit(input[index * 2 + 1]);
                if (high < 0 || low < 0) throw std::runtime_error("media SHA-256 must be lowercase hexadecimal");
                result[index] = static_cast<std::byte>((high << 4) | low);
            }
            return result;
        }

        std::string escapeJson(std::string_view value)
        {
            std::string out{'"'};
            static constexpr char hex[] = "0123456789abcdef";
            for (const unsigned char ch : value)
            {
                switch (ch)
                {
                    case '"': out += "\\\""; break;
                    case '\\': out += "\\\\"; break;
                    case '\b': out += "\\b"; break;
                    case '\f': out += "\\f"; break;
                    case '\n': out += "\\n"; break;
                    case '\r': out += "\\r"; break;
                    case '\t': out += "\\t"; break;
                    default:
                        if (ch < 0x20U)
                        {
                            out += "\\u00";
                            out += hex[ch >> 4U];
                            out += hex[ch & 0x0fU];
                        }
                        else
                            out.push_back(static_cast<char>(ch));
                }
            }
            out.push_back('"');
            return out;
        }

        std::string toJson(const sol::object& value, unsigned depth = 0)
        {
            if (depth > 32)
                throw std::runtime_error("LORKHAN payload nesting exceeds 32 levels");
            if (value == sol::nil || !value.valid()) return "null";
            if (value.is<bool>()) return value.as<bool>() ? "true" : "false";
            if (value.is<std::string>()) return escapeJson(value.as<std::string>());
            if (value.is<double>())
            {
                const double number = value.as<double>();
                if (!std::isfinite(number)) throw std::runtime_error("LORKHAN payload contains a non-finite number");
                std::ostringstream out; out << std::setprecision(17) << number; return out.str();
            }
            if (!value.is<sol::table>())
                throw std::runtime_error("LORKHAN payload contains an unsupported value");
            const sol::table table = value.as<sol::table>();
            std::size_t count = 0;
            bool array = true;
            std::size_t maximum = 0;
            for (const auto& [key, unused] : table)
            {
                static_cast<void>(unused); ++count;
                if (!key.is<int>() || key.as<int>() < 1) array = false;
                else maximum = std::max(maximum, static_cast<std::size_t>(key.as<int>()));
            }
            array = array && maximum == count;
            std::string out = array ? "[" : "{";
            bool first = true;
            if (array)
            {
                for (std::size_t index = 1; index <= maximum; ++index)
                {
                    if (!first)
                        out.push_back(',');
                    first = false;
                    out += toJson(table.get<sol::object>(index), depth + 1);
                }
            }
            else
            {
                for (const auto& [key, item] : table)
                {
                    if (!key.is<std::string>()) throw std::runtime_error("LORKHAN object keys must be strings");
                    if (!first)
                        out.push_back(',');
                    first = false;
                    out += escapeJson(key.as<std::string>()); out.push_back(':'); out += toJson(item, depth + 1);
                }
            }
            out.push_back(array ? ']' : '}');
            if (out.size() > lorkhan::kMaxJsonBytes) throw std::runtime_error("LORKHAN payload exceeds 2 MiB");
            return out;
        }

        // Read static record contributors synchronously without exposing reference-origin guesses.
        sol::table recordProvenanceTable(sol::state_view lua, const MWWorld::Ptr& ptr)
        {
            sol::table result(lua, sol::create), files(lua, sol::create);
            result["state"] = "unavailable";
            result["files"] = files;
            if (ptr.isEmpty()) return result;
            const auto& id = ptr.getCellRef().getRefId();
            result["record_id"] = id.serializeText();
            const bool creature = ptr.getType() == ESM::Creature::sRecordId;
            if (!creature && ptr.getType() != ESM::NPC::sRecordId) return result;
            const auto store = MWBase::Environment::get().getESMStore();
            if (creature ? store->get<ESM::Creature>().isDynamic(id) : store->get<ESM::NPC>().isDynamic(id))
            {
                result["state"] = "dynamic";
                return result;
            }
            const auto* provenance = store->actorRecordProvenance(id, creature);
            if (!provenance || provenance->winningFile.empty()) return result;
            result["state"] = provenance->complete ? "complete" : "truncated";
            result["winning_file"] = provenance->winningFile;
            for (std::size_t i = 0; i < provenance->files.size(); ++i)
                files[i + 1] = provenance->files[i];
            return result;
        }

        sol::table identityTable(sol::state_view lua, const lorkhan::ProtocolIdentity& identity)
        {
            sol::table result(lua, sol::create);
            result["kind"] = identity.kind; result["record_id"] = identity.recordId;
            result["content_file"] = identity.contentFile; result["display_name"] = identity.displayName;
            sol::table refnum(lua, sol::create); refnum["index"] = identity.refnumIndex;
            refnum["content_file"] = identity.refnumContentFile; result["refnum"] = refnum;
            sol::table cell(lua, sol::create);
            if (identity.cell.kind == lorkhan::ProtocolCell::Kind::exterior)
            { cell["kind"] = "exterior"; cell["grid_x"] = identity.cell.gridX; cell["grid_y"] = identity.cell.gridY; }
            else { cell["kind"] = "interior"; cell["name"] = identity.cell.name; }
            result["cell"] = cell;
            return result;
        }

        sol::table canonicalMediaTable(sol::state_view lua, const lorkhan::CanonicalMediaDescriptor& media)
        {
            sol::table result(lua, sol::create);
            result["media_id"] = media.media.value(); result["dialogue_message_id"] = media.dialogueMessage.value();
            result["sha256"] = media.sha256; result["bytes"] = media.bytes;
            result["codec"] = media.codec == lorkhan::MediaCodec::wav ? "wav"
                : media.codec == lorkhan::MediaCodec::ogg ? "ogg" : "mp3";
            result["duration_ms"] = media.durationMs; result["expires_at"] = media.expiresAt;
            return result;
        }

        sol::table canonicalMetadataTable(sol::state_view lua, const lorkhan::CanonicalResponseMetadata& metadata)
        {
            sol::table result(lua, sol::create);
            if (metadata.animation) result["animation"] = *metadata.animation;
            if (metadata.emotion) result["emotion"] = *metadata.emotion;
            if (metadata.mood) result["mood"] = *metadata.mood;
            if (metadata.rechatDepth) result["rechat_depth"] = *metadata.rechatDepth;
            if (metadata.speechEnabled) result["speech_enabled"] = *metadata.speechEnabled;
            if (metadata.source) result["source"] = *metadata.source;
            return result;
        }

        sol::table canonicalLineTable(sol::state_view lua, const lorkhan::CanonicalResponseLine& line)
        {
            sol::table result(lua, sol::create);
            result["schema"] = "lorkhan.response.line.v1"; result["line_id"] = line.line.value();
            result["line_index"] = line.lineIndex; result["speaker"] = line.speaker;
            result["display_name"] = line.displayName; result["speaker_identity"] = identityTable(lua, line.speakerIdentity);
            result["action"] = line.action; result["text"] = line.text; result["subtitle"] = line.subtitle;
            result["tts_text"] = line.ttsText; result["request_id"] = line.request.value();
            result["utterance_id"] = line.utterance.value(); result["listener"] = line.listener;
            result["listener_identity"] = identityTable(lua, line.listenerIdentity);
            result["rechat_target"] = line.rechatTarget;
            result["rechat_target_identity"] = identityTable(lua, line.rechatTargetIdentity);
            result["final_response_line"] = line.finalResponseLine;
            result["metadata"] = canonicalMetadataTable(lua, line.metadata);
            if (line.media) result["media"] = canonicalMediaTable(lua, *line.media);
            if (line.ttsCacheKey) result["tts_cache_key"] = *line.ttsCacheKey;
            if (line.commandName) result["command_name"] = *line.commandName;
            if (line.action == "rolecommand") {
                sol::table arguments(lua, sol::create);
                for (std::size_t index = 0; index < line.commandArgs.size(); ++index)
                    arguments[index + 1] = line.commandArgs[index];
                result["command_args"] = arguments;
            }
            return result;
        }

        sol::table canonicalResponseTable(sol::state_view lua, const lorkhan::CanonicalResponse& response)
        {
            sol::table result(lua, sol::create), lines(lua, sol::create);
            result["schema"] = "lorkhan.response.v1"; result["response_id"] = response.response.value();
            result["installation_id"] = response.installation.value(); result["profile_id"] = response.profile.value();
            result["playthrough_id"] = response.playthrough.value(); result["session_id"] = response.session.value();
            result["turn_id"] = response.turn.value(); result["request_id"] = response.request.value();
            result["generation"] = response.generation.value();
            result["runtime_generation"] = response.runtimeGeneration.value(); result["created_at"] = response.createdAt;
            result["ok"] = response.ok; result["close"] = response.close; result["error"] = response.error;
            for (std::size_t index = 0; index < response.lines.size(); ++index)
                lines[index + 1] = canonicalLineTable(lua, response.lines[index]);
            result["lines"] = lines;
            return result;
        }

        MWWorld::Ptr mutablePtrOrThrow(const sol::object& object)
        {
            ObjectVariant variant(object);
            if (variant.isLObject())
                throw std::runtime_error("Local scripts can only modify the object they are attached to.");
            MWWorld::Ptr ptr = variant.ptr();
            if (ptr.isEmpty())
                throw std::runtime_error("Invalid object");
            return ptr;
        }

        // Classify only engine states that make an actor unable to take a fresh conversation turn.
        std::tuple<sol::object, sol::object> actorConversationState(sol::state_view lua, const sol::object& actor)
        {
            try
            {
                const MWWorld::Ptr ptr = mutablePtrOrThrow(actor);
                if (!ptr.getClass().isActor())
                    return { sol::make_object(lua, sol::nil), sol::make_object(lua, "actor_required") };
                const MWMechanics::CreatureStats& stats = ptr.getClass().getCreatureStats(ptr);
                std::string state = "active";
                if (stats.isDead())
                    state = "inactive";
                else if (stats.getKnockedDown() || stats.isParalyzed())
                    state = "unconscious";
                else if (stats.getAiSequence().isInCombat() || stats.getAiSequence().isInPursuit()
                    || MWBase::Environment::get().getMechanicsManager()->isAttackingOrSpell(ptr))
                    state = "busy";
                sol::table result(lua, sol::create);
                result["state"] = state;
                return { sol::make_object(lua, result), sol::make_object(lua, sol::nil) };
            }
            catch (const std::exception& error)
            {
                return { sol::make_object(lua, sol::nil), sol::make_object(lua, error.what()) };
            }
        }

        class NativeClient
        {
            struct MediaState {
                std::string state;
                std::filesystem::path cachePath;
                std::string reason;
                std::optional<lorkhan::RequestId> request;
            };
            struct MenuDialogueState {
                std::string state;
                std::string reason;
                std::optional<lorkhan::RequestId> request;
                std::optional<lorkhan::CanonicalMediaDescriptor> media;
            };
            struct PlayerAutochatState {
                std::string state;
                std::string text;
                std::string reason;
                std::optional<lorkhan::RequestId> request;
            };

            struct TransferActor {
                lorkhan::ProtocolIdentity identity;
                MWWorld::SafePtr object;
                int gold{};
                int observedGold{};
                std::vector<std::string> services;
                std::vector<std::string> spells;
            };
            struct TransferItem {
                std::string id, record, location;
                MWWorld::SafePtr object, owner;
                int count{};
            };
            struct AdvancedDestination {
                std::string id, name;
                ESM::RefId cell;
                ESM::Position position{};
                MWWorld::SafePtr actor;
                bool actorTarget{};
            };
            struct TransferSnapshot {
                std::string session;
                std::uint64_t generation{};
                bool cancelled{}, advanced{};
                ESM::RefId playerCell;
                std::vector<std::string> advancedItems, advancedActors, advancedExactRecords;
                std::map<std::string,std::size_t> advancedItemNames, advancedActorNames;
                std::vector<AdvancedDestination> destinations;
                std::vector<TransferActor> actors;
                std::vector<TransferItem> items;
            };
            struct TransferRecord {
                std::shared_ptr<const lorkhan::ActionIntent> intent;
                std::shared_ptr<TransferSnapshot> snapshot;
                lorkhan::ActionCommitGate gate;
                bool spellHook{},spellStarted{};
                std::string status="awaiting_confirmation", reason;
                std::string record;
                int count{}, sourceCount{}, targetCount{};
                std::vector<std::string> createdIds;
                std::string destinationCell;
                double x{},y{},z{};
                std::optional<lorkhan::ActionResultRequest> receipt;
                std::optional<lorkhan::RequestId> receiptRequest;
                std::string receiptStatus="not_submitted", receiptReason;
            };

        public:
            NativeClient()
            {
                try
                {
                    m_config = loadConfig();
                    m_legacyPlaythrough=m_config->playthrough.value();
                    auto transport = std::make_unique<lorkhan::BeastTransport>(m_config->baseUrl,
                        m_config->installation, lorkhan::PairingToken(m_config->key), m_config->cacheRoot);
                    m_transport=transport.get();m_transport->setConnectionTimeout(30);
                    m_service = std::make_unique<lorkhan::BridgeService>(std::move(transport),
                        std::make_shared<lorkhan::SystemClock>(), processGeneration());
                    m_status = "waiting_identity";
                }
                catch (const std::exception& error) { m_status = "unconfigured"; m_error = error.what(); }
            }

            ~NativeClient()
            {
                lorkhan::VoiceCaptureService::instance().halt();
                if (m_service) m_service->halt();
            }

            std::tuple<sol::object, sol::object> startVoiceCapture(
                sol::state_view lua, bool automatic, int rmsThreshold, int trailingSilenceMs, int deviceId)
            {
                if (!ready()) return failure(lua, "bridge_not_ready");
                auto started = lorkhan::VoiceCaptureService::instance().start(automatic,
                    static_cast<std::uint16_t>(rmsThreshold), static_cast<std::uint32_t>(trailingSilenceMs), deviceId);
                if (!started) return failure(lua, started.error().message);
                return success(lua, "recording");
            }

            void stopVoiceCapture() { lorkhan::VoiceCaptureService::instance().stop(); }
            void cancelVoiceCapture() { lorkhan::VoiceCaptureService::instance().halt(); }

            sol::table voiceCaptureStatus(sol::state_view lua) const
            {
                const auto& capture=lorkhan::VoiceCaptureService::instance();sol::table result(lua,sol::create);
                const char* name="idle";switch(capture.state()){
                    case lorkhan::VoiceCaptureState::unsupported:name="unsupported";break;
                    case lorkhan::VoiceCaptureState::idle:break;
                    case lorkhan::VoiceCaptureState::recording:name="recording";break;
                    case lorkhan::VoiceCaptureState::ready:name="ready";break;
                    case lorkhan::VoiceCaptureState::failed:name="failed";break;}
                result["state"]=name;result["bytes"]=capture.capturedBytes();result["duration_ms"]=capture.durationMs();
                result["automatic"]=capture.automatic();result["voice_detected"]=capture.voiceDetected();
                result["device_id"]=capture.deviceId();result["device_name"]=capture.selectedDeviceName();
                result["pcm_bytes"]=capture.capturedPcmBytes();result["peak_amplitude"]=capture.peakAmplitude();
                result["rms_amplitude"]=capture.rmsAmplitude();
                const std::string error=capture.error();if(!error.empty())result["error"]=error;return result;
            }

            std::tuple<sol::object, sol::object> submitCapturedStt(sol::state_view lua,const std::string& language)
            {
                if(!ready())return failure(lua,"bridge_not_ready");auto captured=lorkhan::VoiceCaptureService::instance().takeReady();
                if(!captured)return failure(lua,"voice_capture_not_ready");try{
                    const lorkhan::RequestId request(uuid());lorkhan::EnvelopeIds ids{m_config->installation,m_config->profile,
                        m_config->playthrough,*m_session,request,lorkhan::TurnId(uuid()),lorkhan::MessageId(uuid()),m_service->generation()};
                    const std::string createdAt=utcNow();lorkhan::OutboundRequest outbound{request,*m_session,ids.generation,
                        lorkhan::RequestKind::stt,lorkhan::SttRequest{ids,createdAt,"wav",language,captured->sha256,std::move(captured->wav)}};
                    auto accepted=m_service->enqueue(std::move(outbound));if(!accepted)return failure(lua,accepted.error().message);
                    sol::table result(lua,sol::create);result["message_id"]=ids.message.value();result["request_id"]=ids.request.value();
                    result["turn_id"]=ids.turn.value();result["session_id"]=ids.session.value();result["generation"]=ids.generation.value();
                    result["created_at"]=createdAt;return{sol::make_object(lua,result),sol::make_object(lua,sol::nil)};
                }catch(const std::exception& error){return failure(lua,error.what());}
            }
            NativeClient(const NativeClient&) = delete;
            NativeClient& operator=(const NativeClient&) = delete;

            std::string status() const { return m_status; }
            std::string error() const { return m_error; }
            std::uint64_t generation() const { return m_service ? m_service->generation().value() : 0; }
            bool ready() const { return m_service && m_session.has_value() && m_status == "ready"; }
            std::optional<LorkhanObservationScope> observationScope() const
            {
                if (!ready()) return std::nullopt;
                return LorkhanObservationScope{m_session->value(), m_service->generation().value()};
            }

            std::string serverBaseUrl() const
            {
                return m_config ? "http://" + m_config->baseUrl.authority() + m_config->baseUrl.basePath : "";
            }

            sol::table diagnostics(sol::state_view lua) const
            {
                sol::table result(lua, sol::create);
                if (!m_service) return result;
                const auto value = m_service->diagnostics();
                result["outbound"] = value.outbound;
                result["inbound"] = value.inbound;
                result["active"] = value.active;
                result["cancellations"] = value.cancellations;
                result["init_pending"] = m_initRequest.has_value();
                result["results_seen"] = m_resultsSeen;
                result["init_matches"] = m_initMatches;
                return result;
            }

            sol::object sessionInfo(sol::state_view lua) const
            {
                if (!m_session) return sol::make_object(lua, sol::nil);
                sol::table result(lua, sol::create);
                result["session_id"] = m_session->value();
                result["generation"] = m_service->generation().value();
                result["config_revision"] = m_configRevision;
                if (m_clientSettings)
                {
                    const auto& settings = *m_clientSettings;
                    sol::table document(lua, sol::create), behavior(lua, sol::create), memory(lua, sol::create);
                    sol::table narrator(lua, sol::create), presentation(lua, sol::create), safety(lua, sol::create);
                    document["schema"] = "lorkhan.client-settings.v1";
                    behavior["auto_greeting"] = settings.behavior.autoGreeting;
                    behavior["rechat"] = settings.behavior.rechat;
                    behavior["rechat_delay_seconds"] = settings.behavior.rechatDelaySeconds;
                    behavior["rechat_max_depth"] = settings.behavior.rechatMaxDepth;
                    behavior["rechat_probability_percent"] = settings.behavior.rechatProbabilityPercent;
                    behavior["rechat_mode"] = settings.behavior.rechatMode;
                    behavior["rechat_strict_targeting"] = settings.behavior.rechatStrictTargeting;
                    behavior["open_rechat"] = settings.behavior.openRechat;
                    behavior["rechat_allow_actions"] = settings.behavior.rechatAllowActions;
                    behavior["end_conversation_cooldown_seconds"] = settings.behavior.endConversationCooldownSeconds;
                    behavior["boredom"] = settings.behavior.boredom;
                    behavior["boredom_delay_seconds"] = settings.behavior.boredomDelaySeconds;
                    behavior["combat_barks"] = settings.behavior.combatBarks;
                    behavior["ai_enabled"] = settings.behavior.aiEnabled;
                    behavior["combat_bark_period_seconds"] = settings.behavior.combatBarkPeriodSeconds;
                    memory["recent_turn_limit"] = settings.memory.recentTurnLimit;
                    memory["knowledge_limit"] = settings.memory.knowledgeLimit;
                    narrator["enabled"] = settings.narrator.enabled;
                    narrator["name"] = settings.narrator.name;
                    narrator["context_visibility"] = settings.narrator.contextVisibility;
                    narrator["inline_mode"] = settings.narrator.inlineMode;
                    narrator["welcome_events"] = settings.narrator.welcomeEvents;
                    narrator["welcome_cooldown_minutes"] = settings.narrator.welcomeCooldownMinutes;
                    narrator["random_events"] = settings.narrator.randomEvents;
                    narrator["random_chance_percent"] = settings.narrator.randomChancePercent;
                    narrator["random_cooldown_rounds"] = settings.narrator.randomCooldownRounds;
                    narrator["bored_events"] = settings.narrator.boredEvents;
                    narrator["bored_chance_percent"] = settings.narrator.boredChancePercent;
                    narrator["quest_events"] = settings.narrator.questEvents;
                    narrator["quest_chance_percent"] = settings.narrator.questChancePercent;
                    narrator["quest_cooldown_minutes"] = settings.narrator.questCooldownMinutes;
                    narrator["book_events"] = settings.narrator.bookEvents;
                    presentation["show_status_hud"] = settings.presentation.showStatusHud;
                    presentation["transcript_rows"] = settings.presentation.transcriptRows;
                    presentation["tts_volume_boost"] = settings.presentation.ttsVolumeBoost;
                    safety["actions_enabled"] = settings.safety.actionsEnabled;
                    safety["allow_hostile"] = settings.safety.allowHostile;
                    safety["allow_creatures"] = settings.safety.allowCreatures;
                    document["behavior"] = behavior; document["memory"] = memory; document["narrator"] = narrator;
                    document["presentation"] = presentation; document["safety"] = safety;
                    result["client_settings"] = document;
                }
                return sol::make_object(lua, result);
            }

            sol::object nextTurnMetadata(sol::state_view lua)
            {
                if (!ready()) return sol::make_object(lua, sol::nil);
                sol::table result(lua, sol::create);
                result["message_id"] = uuid(); result["request_id"] = uuid(); result["turn_id"] = uuid();
                result["installation_id"] = m_config->installation.value(); result["profile_id"] = m_config->profile.value();
                result["playthrough_id"] = m_config->playthrough.value(); result["session_id"] = m_session->value();
                result["generation"] = m_service->generation().value(); result["created_at"] = utcNow();
                result["platform"] = m_config->platform; result["content_fingerprint"] = m_config->fingerprint;
                return sol::make_object(lua, result);
            }

            std::tuple<sol::object, sol::object> submitTurn(sol::state_view lua, sol::table dto)
            {
                if (!ready()) return failure(lua, "bridge_not_ready");
                try
                {
                    lorkhan::EnvelopeIds ids{ m_config->installation, m_config->profile, m_config->playthrough,
                        lorkhan::SessionId(dto.get<std::string>("session_id")), lorkhan::RequestId(dto.get<std::string>("request_id")),
                        lorkhan::TurnId(dto.get<std::string>("turn_id")), lorkhan::MessageId(dto.get<std::string>("message_id")),
                        lorkhan::Generation(dto.get<std::uint64_t>("generation")) };
                    lorkhan::RuntimeInfo runtime;
                    runtime.platform = m_config->platform;
                    sol::table runtimeTable = dto["runtime"];
                    sol::table capabilities = runtimeTable["capabilities"];
                    for (std::size_t index = 1; index <= capabilities.size(); ++index)
                        runtime.capabilities.push_back(capabilities.get<std::string>(index));
                    sol::table payloadTable = dto["payload"];
                    auto transferSnapshot = captureTransferSnapshot(lua, payloadTable);
                    const std::string payload = toJson(dto.get<sol::object>("payload"));
                    const std::string requestId=ids.request.value();
                    const std::string turnId=ids.turn.value();
                    lorkhan::OutboundRequest request{ ids.request, ids.session, ids.generation, lorkhan::RequestKind::turn,
                        lorkhan::TurnRequest{ std::move(ids), lorkhan::Generation(dto.get<std::uint64_t>("runtime_generation")),
                            std::move(runtime), dto.get<std::string>("content_fingerprint"),
                            dto.get<std::string>("created_at"), payload } };
                    auto accepted = m_service->enqueue(std::move(request));
                    if (!accepted) return failure(lua, accepted.error().message);
                    m_turnRequests.emplace(requestId,turnId);
                    if (!m_transferSnapshots.contains(turnId)) {
                        if (m_transferSnapshots.size() >= 16) {
                            m_transferSnapshots.erase(m_transferOrder.front());m_transferOrder.pop_front();
                        }
                        m_transferSnapshots[turnId] = std::move(transferSnapshot);
                        m_transferOrder.push_back(turnId);
                    }
                    return success(lua, accepted.value().value());
                }
                catch (const std::exception& error) { return failure(lua, error.what()); }
            }

            // Submit one schema-owned game observation without exposing a generic Lua transport primitive.
            std::tuple<sol::object, sol::object> submitGameData(
                sol::state_view lua, lorkhan::GameDataType type, sol::table payload)
            {
                if (!ready()) return failure(lua, "bridge_not_ready");
                try
                {
                    const lorkhan::RequestId request(uuid());
                    const std::string serialized = toJson(sol::make_object(lua, payload));
                    lorkhan::OutboundRequest outbound{request, *m_session, m_service->generation(),
                        lorkhan::RequestKind::gamedata,
                        lorkhan::GameDataRequest{m_config->installation, m_config->playthrough, request,
                            m_service->generation(), utcNow(), type, serialized}};
                    auto accepted = m_service->enqueue(std::move(outbound));
                    if (!accepted) return failure(lua, accepted.error().message);
                    return success(lua, request.value());
                }
                catch (const std::exception& error) { return failure(lua, error.what()); }
            }

            std::tuple<sol::object, sol::object> submitCapturedDialogue(sol::state_view lua, sol::table payload)
            {
                return submitGameData(lua, lorkhan::GameDataType::captured_dialogue, std::move(payload));
            }

            std::tuple<sol::object, sol::object> submitInventory(sol::state_view lua, sol::table payload)
            {
                return submitGameData(lua, lorkhan::GameDataType::inventory, std::move(payload));
            }

            static std::string_view serviceName(lorkhan::ActionIntentKind kind)
            {
                using K=lorkhan::ActionIntentKind;
                switch(kind){
                    case K::service_barter:return "barter";
                    case K::service_training:return "training";
                    case K::service_spells:return "spells";
                    case K::service_travel:return "travel";
                    case K::service_spellmaking:return "spellmaking";
                    case K::service_enchanting:return "enchanting";
                    case K::service_repair:return "repair";
                    default:return {};
                }
            }

            // Offered services are observation only; refusal scripts run only when opening the menu.
            static std::vector<std::string> knownSpells(const MWWorld::Ptr& ptr)
            {
                std::vector<std::string> result;if(ptr.isEmpty()||!ptr.getClass().isActor())return result;
                for(const auto* spell:ptr.getClass().getCreatureStats(ptr).getSpells()){
                    if(result.size()>=128)break;
                    if((spell->mData.mType==ESM::Spell::ST_Spell||spell->mData.mType==ESM::Spell::ST_Power)
                        &&!spell->mId.serializeText().empty()&&spell->mId.serializeText().size()<=256
                        &&!spell->mName.empty()&&spell->mName.size()<=256)
                        result.push_back(spell->mId.serializeText());
                }
                return result;
            }

            static std::vector<std::string> offeredServices(const MWWorld::Ptr& ptr)
            {
                std::vector<std::string> offered;
                if(ptr.isEmpty()||!ptr.getClass().isActor())return offered;
                const int flags=ptr.getClass().getServices(ptr);
                if(flags&ESM::NPC::AllItems)offered.emplace_back("barter");
                if(flags&ESM::NPC::Training)offered.emplace_back("training");
                if(flags&ESM::NPC::Spells)offered.emplace_back("spells");
                if(flags&ESM::NPC::Spellmaking)offered.emplace_back("spellmaking");
                if(flags&ESM::NPC::Enchanting)offered.emplace_back("enchanting");
                if(flags&ESM::NPC::Repair)offered.emplace_back("repair");
                if((ptr.getType()==ESM::NPC::sRecordId&&!ptr.get<ESM::NPC>()->mBase->getTransport().empty())
                    ||(ptr.getType()==ESM::Creature::sRecordId&&!ptr.get<ESM::Creature>()->mBase->getTransport().empty()))
                    offered.emplace_back("travel");
                return offered;
            }

            static sol::table actorServices(sol::state_view lua,const MWWorld::Ptr& ptr)
            {
                sol::table result(lua,sol::create),services(lua,sol::create);
                result["state"]=!ptr.isEmpty()&&ptr.getClass().isActor()?"known":"unavailable";
                for(const auto& name:offeredServices(ptr))services.add(name);
                result["services"]=services;return result;
            }

            static sol::table actorSpells(sol::state_view lua,const MWWorld::Ptr& ptr)
            {
                sol::table result(lua,sol::create),spells(lua,sol::create);
                result["state"]=!ptr.isEmpty()&&ptr.getClass().isActor()?"known":"unavailable";
                for(const auto& id:knownSpells(ptr)){
                    sol::table row(lua,sol::create);row["spell_id"]=id;
                    const auto* spell=MWBase::Environment::get().getESMStore()->get<ESM::Spell>().search(ESM::RefId::deserializeText(id));
                    row["name"]=spell?spell->mName:id;spells.add(row);
                }
                result["spells"]=spells;return result;
            }

            static bool advancedKind(lorkhan::ActionIntentKind kind)
            {
                using K=lorkhan::ActionIntentKind;
                return kind==K::item_create||kind==K::gold_create||kind==K::actor_spawn
                    ||kind==K::actor_teleport_to_player||kind==K::player_teleport||kind==K::actor_restore
                    ||kind==K::actor_resurrect||kind==K::actor_kill;
            }

            static bool transferKind(lorkhan::ActionIntentKind kind)
            {
                using K=lorkhan::ActionIntentKind;
                return advancedKind(kind)||kind==K::spell_cast||!serviceName(kind).empty()||kind==K::item_give||kind==K::item_take||kind==K::item_pickup||kind==K::gold_give||kind==K::gold_take;
            }

            static bool sameTransferActor(const lorkhan::ProtocolIdentity& left,const lorkhan::ProtocolIdentity& right)
            {
                return left.kind==right.kind && left.recordId==right.recordId && left.contentFile==right.contentFile
                    && left.refnumIndex==right.refnumIndex && left.refnumContentFile==right.refnumContentFile;
            }

            // Resolve the witnessed actor, never an arbitrary first instance of a record.
            static MWWorld::Ptr transferActorPtr(const lorkhan::ProtocolIdentity& identity)
            {
                auto& environment=MWBase::Environment::get();
                MWWorld::Ptr ptr;
                if(identity.kind=="player") ptr=environment.getWorld()->getPlayerPtr();
                else if(identity.refnumIndex<=std::numeric_limits<std::uint32_t>::max()
                    && identity.refnumContentFile<=static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max()))
                    ptr=environment.getWorldModel()->getPtr(ESM::RefNum{static_cast<std::uint32_t>(identity.refnumIndex),
                        static_cast<std::int32_t>(identity.refnumContentFile)});
                if(ptr.isEmpty()||!ptr.getClass().isActor()||ptr.getCellRef().getRefId().serializeText()!=identity.recordId)
                    return {};
                if(identity.kind!="player"&&identity.kind!=(ptr.getClass().isNpc()?"npc":"creature"))return {};
                return ptr;
            }

            static bool transferNear(const MWWorld::Ptr& left,const MWWorld::Ptr& right,double distance)
            {
                if(left.isEmpty()||right.isEmpty()||!left.isInCell()||!right.isInCell()
                    ||!left.getRefData().isEnabled()||!right.getRefData().isEnabled())return false;
                if(left.getCell()!=right.getCell()
                    && !(left.getCell()->getCell()->isExterior()&&right.getCell()->getCell()->isExterior()))return false;
                const auto& a=left.getRefData().getPosition();const auto& b=right.getRefData().getPosition();
                double squared=0;for(int i=0;i<3;++i){const double delta=a.pos[i]-b.pos[i];squared+=delta*delta;}
                return std::isfinite(squared)&&squared<=distance*distance;
            }

            void syncTransferScope()
            {
                const std::string session=m_session?m_session->value():"";
                if(m_transferSession==session&&m_transferGeneration==generation())return;
                m_transfers.clear();m_transferSnapshots.clear();m_transferOrder.clear();
                m_transferSession=session;m_transferGeneration=generation();
            }

            // Capture only objects already named in this bounded, submitted observation.
            std::shared_ptr<TransferSnapshot> captureTransferSnapshot(sol::state_view lua,sol::table payload)
            {
                syncTransferScope();
                auto snapshot=std::make_shared<TransferSnapshot>();snapshot->session=m_transferSession;
                snapshot->generation=m_transferGeneration;
                const auto observeActor=[&](sol::object candidate){
                    if(!candidate.is<sol::table>()||snapshot->actors.size()>=32)return;
                    sol::table original=candidate.as<sol::table>(),identity(lua,sol::create);
                    for(const char* field:{"kind","record_id","refnum","content_file","cell","display_name"})
                        identity[field]=original.get<sol::object>(field);
                    auto parsed=lorkhan::parseProtocolIdentity(toJson(sol::make_object(lua,identity)));
                    if(!parsed)return;
                    for(const auto& actor:snapshot->actors)if(sameTransferActor(actor.identity,parsed.value()))return;
                    const auto ptr=transferActorPtr(parsed.value());if(ptr.isEmpty())return;
                    const auto player=MWBase::Environment::get().getWorld()->getPlayerPtr();
                    if(!transferNear(ptr,player,2048))return;
                    snapshot->actors.push_back({parsed.value(),MWWorld::SafePtr(ptr),
                        ptr.getClass().getContainerStore(ptr).count(ESM::RefId::stringRefId("gold_001")),0,offeredServices(ptr),knownSpells(ptr)});
                };
                observeActor(payload.get<sol::object>("speaker"));observeActor(payload.get<sol::object>("target"));
                sol::object audience=payload["audience"];
                if(audience.is<sol::table>())for(std::size_t i=1;i<=std::min<std::size_t>(16,audience.as<sol::table>().size());++i)
                    observeActor(audience.as<sol::table>().get<sol::object>(i));
                sol::object contextObject=payload["context"];if(!contextObject.is<sol::table>())return snapshot;
                sol::table context=contextObject.as<sol::table>();
                observeActor(context.get<sol::object>("player"));
                sol::object targetStateObject=context["targetState"];
                sol::table targetState=targetStateObject.is<sol::table>()?targetStateObject.as<sol::table>():sol::table(lua,sol::create);
                sol::table services(lua,sol::create),spells(lua,sol::create);bool servicesKnown=false;
                auto targetIdentity=lorkhan::parseProtocolIdentity(toJson(payload.get<sol::object>("target")));
                if(targetIdentity)for(const auto& actor:snapshot->actors)if(sameTransferActor(actor.identity,targetIdentity.value())){
                    servicesKnown=true;for(const auto& name:actor.services)services.add(name);
                    for(const auto& id:actor.spells){sol::table row(lua,sol::create);row["spell_id"]=id;
                        const auto* spell=MWBase::Environment::get().getESMStore()->get<ESM::Spell>().search(ESM::RefId::deserializeText(id));
                        row["name"]=spell?spell->mName:id;spells.add(row);
                    }break;
                }
                targetState["services"]=services;targetState["services_known"]=servicesKnown;context["targetState"]=targetState;
                targetState["spells"]=spells;targetState["spells_known"]=servicesKnown;

                sol::object nearby=context["nearbyActors"];
                if(nearby.is<sol::table>()){
                    sol::object items=nearby.as<sol::table>()["items"];
                    if(items.is<sol::table>())for(std::size_t i=1;i<=std::min<std::size_t>(12,items.as<sol::table>().size());++i)
                        observeActor(items.as<sol::table>().get<sol::object>(i));
                }
                sol::table actionStates(lua,sol::create);std::size_t actionSpellRows=0,actionSpellBytes=0;
                for(const auto& actor:snapshot->actors){
                    if(actionStates.size()>=12)break;if(actor.identity.kind=="player")continue;
                    sol::table row(lua,sol::create);
                    row["actor"]=identityTable(lua,actor.identity);
                    row["services_known"]=true;row["spells_known"]=true;
                    row["services"]=actorServices(lua,actor.object.ptrOrEmpty())["services"];
                    sol::table spellRows(lua,sol::create);bool truncated=false;
                    for(const auto& id:actor.spells){
                        const auto* spell=MWBase::Environment::get().getESMStore()->get<ESM::Spell>().search(ESM::RefId::deserializeText(id));
                        if(!spell)continue;
                        const auto bytes=id.size()+spell->mName.size()+64;
                        if(actionSpellRows>=128||actionSpellBytes+bytes>32768){truncated=true;break;}
                        sol::table spellRow(lua,sol::create);spellRow["spell_id"]=id;spellRow["name"]=spell->mName;
                        spellRows.add(spellRow);++actionSpellRows;actionSpellBytes+=bytes;
                    }
                    row["spells"]=spellRows;row["spells_truncated"]=truncated;
                    actionStates.add(row);
                }
                context["actorActionStates"]=actionStates;
                captureAdvancedSnapshot(lua,payload,context,*snapshot);
                sol::object list=context["action_items"];if(!list.is<sol::table>())return snapshot;
                const auto rows=list.as<sol::table>();
                for(std::size_t i=1;i<=std::min<std::size_t>(128,rows.size());++i){
                    try{
                        const sol::table row=rows.get<sol::table>(i);const auto id=row.get<std::string>("item_id");
                        if(id.size()>19)continue;
                        const auto ref=ESM::RefId::deserializeText(id);const auto form=ref.getIf<ESM::FormId>();
                        if(!form||form->toString()!=id)continue;
                        const auto ptr=MWBase::Environment::get().getWorldModel()->getPtr(*form);
                        if(ptr.isEmpty()||!ptr.getClass().isItem(ptr)||ptr.getCellRef().getCount()<=0)continue;
                        const auto record=row.get<std::string>("record_id");const int count=row.get<int>("count");
                        bool duplicate=false;for(const auto& existing:snapshot->items)if(existing.id==id)duplicate=true;
                        if(duplicate)continue;
                        if(record!=ptr.getCellRef().getRefId().serializeText()||count!=ptr.getCellRef().getCount())continue;
                        const auto location=row.get<std::string>("location");MWWorld::Ptr owner;
                        if(location=="ground"){
                            if(!ptr.isInCell()||!transferNear(ptr,MWBase::Environment::get().getWorld()->getPlayerPtr(),2048))continue;
                        }else if(location=="actor_inventory"||location=="player_inventory"){
                            auto parsed=lorkhan::parseProtocolIdentity(toJson(row.get<sol::object>("owner")));if(!parsed)continue;
                            observeActor(row.get<sol::object>("owner"));
                            for(auto& actor:snapshot->actors)if(sameTransferActor(actor.identity,parsed.value())){
                                owner=actor.object.ptrOrEmpty();
                                if(owner.isEmpty()||ptr.getContainerStore()!=&owner.getClass().getContainerStore(owner))owner={};
                                else if((location=="player_inventory")!=(parsed.value().kind=="player"))owner={};
                                else if(record=="gold_001"&&actor.observedGold<=std::numeric_limits<int>::max()-count)
                                    actor.observedGold+=count;
                                break;
                            }
                            if(owner.isEmpty())continue;
                        }else continue;
                        snapshot->items.push_back({id,record,location,MWWorld::SafePtr(ptr),owner.isEmpty()?MWWorld::SafePtr():MWWorld::SafePtr(owner),count});
                    }catch(const std::exception&){/* Malformed or stale observations provide no mutation authority. */}
                }
                return snapshot;
            }

            // A bounded explicit text match selects existing loaded records, never arbitrary model IDs.
            static bool advancedMention(const std::string& text,std::string name)
            {
                if(name.empty()||name.size()>256||text.size()>16000)return false;
                const auto lower=[](unsigned char c){return static_cast<char>(std::tolower(c));};
                std::transform(name.begin(),name.end(),name.begin(),lower);
                for(auto offset=text.find(name);offset!=std::string::npos;offset=text.find(name,offset+1)){
                    const auto word=[](unsigned char c){return std::isalnum(c)||c=='_'||c>=128;};
                    if((offset==0||!word(text[offset-1]))&&(offset+name.size()==text.size()||!word(text[offset+name.size()])))return true;
                }
                return false;
            }

            template<class T>
            static void advancedRecords(sol::state_view lua,const std::string& text,sol::table& rows,
                TransferSnapshot& snapshot,const char* kind=nullptr)
            {
                auto& records=kind?snapshot.advancedActors:snapshot.advancedItems;
                auto& names=kind?snapshot.advancedActorNames:snapshot.advancedItemNames;
                for(const auto& record:MWBase::Environment::get().getESMStore()->get<T>()){
                    const auto id=record.mId.serializeText();
                    if(kind&&id=="player")continue;
                    // Currency denominations normalize on insertion; use the dedicated gold action.
                    if(!kind&&(id=="gold_001"||id=="gold_005"||id=="gold_010"||id=="gold_025"||id=="gold_100"))continue;
                    if(id.empty()||id.size()>256||record.mName.empty()||record.mName.size()>256
                        ||id.find_first_of("/\\\r\n\t")!=std::string::npos)continue;
                    const bool exact=advancedMention(text,id);
                    const bool nameMatch=advancedMention(text,record.mName)||advancedMention(text,record.mName+"s");
                    if(!exact&&!nameMatch)continue;
                    std::string name=record.mName;
                    std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c){return static_cast<char>(std::tolower(c));});
                    if(records.size()>=16){if(names.contains(name))++names[name];continue;}
                    if(std::find(records.begin(),records.end(),id)!=records.end())continue;
                    ++names[name];if(exact)snapshot.advancedExactRecords.push_back(id);
                    sol::table row(lua,sol::create);row["record_id"]=id;row["name"]=record.mName;
                    if(kind)row["kind"]=kind;rows.add(row);records.push_back(id);
                }
            }

            static void captureAdvancedSnapshot(sol::state_view lua,sol::table payload,sol::table context,TransferSnapshot& snapshot)
            {
                sol::table advanced(lua,sol::create),items(lua,sol::create),actors(lua,sol::create),destinations(lua,sol::create);
                advanced["items"]=items;advanced["actors"]=actors;advanced["destinations"]=destinations;
                context["advanced_actions"]=advanced;
                const std::string mode=payload.get_or("execution_mode",std::string());
                const std::string source=payload.get_or("ui_source",std::string());
                if((mode!="cheat"&&mode!="narrator")||(source!="lorkhan_text"&&source!="lorkhan_voice"))return;
                const auto input=payload.get<sol::object>("input");if(!input.is<sol::table>())return;
                auto text=input.as<sol::table>().get_or("text",std::string());if(text.empty()||text.size()>16000)return;
                std::transform(text.begin(),text.end(),text.begin(),[](unsigned char c){return static_cast<char>(std::tolower(c));});
                const auto player=MWBase::Environment::get().getWorld()->getPlayerPtr();
                if(player.isEmpty()||!player.isInCell()||player.getClass().getCreatureStats(player).isDead())return;
                snapshot.advanced=true;snapshot.playerCell=player.getCell()->getCell()->getId();
                advancedRecords<ESM::Armor>(lua,text,items,snapshot);
                advancedRecords<ESM::Weapon>(lua,text,items,snapshot);
                advancedRecords<ESM::Clothing>(lua,text,items,snapshot);
                advancedRecords<ESM::Potion>(lua,text,items,snapshot);
                advancedRecords<ESM::Ingredient>(lua,text,items,snapshot);
                advancedRecords<ESM::Miscellaneous>(lua,text,items,snapshot);
                advancedRecords<ESM::Book>(lua,text,items,snapshot);
                advancedRecords<ESM::Apparatus>(lua,text,items,snapshot);
                advancedRecords<ESM::Lockpick>(lua,text,items,snapshot);
                advancedRecords<ESM::Probe>(lua,text,items,snapshot);
                advancedRecords<ESM::Repair>(lua,text,items,snapshot);
                advancedRecords<ESM::Light>(lua,text,items,snapshot);
                advancedRecords<ESM::NPC>(lua,text,actors,snapshot,"npc");
                advancedRecords<ESM::Creature>(lua,text,actors,snapshot,"creature");
                const auto appendDestination=[&](AdvancedDestination destination){
                    destination.id="destination:"+std::to_string(snapshot.destinations.size()+1);
                    sol::table row(lua,sol::create);row["destination_id"]=destination.id;row["name"]=destination.name;
                    destinations.add(row);snapshot.destinations.push_back(std::move(destination));
                };
                for(const auto& seen:snapshot.actors){
                    if(snapshot.destinations.size()>=16)break;
                    const auto ptr=seen.object.ptrOrEmpty();
                    if(ptr.isEmpty()||ptr==player||!advancedMention(text,std::string(ptr.getClass().getName(ptr))))continue;
                    appendDestination({{},std::string(ptr.getClass().getName(ptr)),ptr.getCell()->getCell()->getId(),
                        ptr.getRefData().getPosition(),MWWorld::SafePtr(ptr),true});
                }
                const auto& cells=MWBase::Environment::get().getESMStore()->get<ESM::Cell>();
                std::vector<std::string> cellNames;
                for(std::size_t i=0;i<cells.getSize()&&snapshot.destinations.size()<16;++i){
                    const auto* cell=cells.at(i);if(!cell||!advancedMention(text,cell->mName))continue;
                    if(cell->mName.size()>256||std::find(cellNames.begin(),cellNames.end(),cell->mName)!=cellNames.end())continue;
                    cellNames.push_back(cell->mName);ESM::Position position{};
                    auto world=MWBase::Environment::get().getWorld();
                    ESM::RefId cellId=world->findExteriorPosition(cell->mName,position);
                    if(cellId.empty())cellId=world->findInteriorPosition(cell->mName,position);
                    if(cellId.empty())continue;
                    bool finite=true;for(int j=0;j<3;++j)finite=finite&&std::isfinite(position.pos[j])&&std::isfinite(position.rot[j]);
                    if(finite)appendDestination({{},cell->mName,cellId,position,{}});
                }
            }

            void retainTransfer(const lorkhan::ProtocolEvent& event)
            {
                syncTransferScope();
                if(event.correlation.session.value()!=m_transferSession||event.correlation.generation.value()!=m_transferGeneration)return;
                const auto snapshot=m_transferSnapshots.find(event.correlation.turn.value());
                if(event.type==lorkhan::ProtocolEventType::turn_cancelled||event.type==lorkhan::ProtocolEventType::turn_failed){
                    if(snapshot!=m_transferSnapshots.end())snapshot->second->cancelled=true;
                    for(auto& [id,record]:m_transfers)if(record.intent->turn==event.correlation.turn)cancelTransfer(id);
                    return;
                }
                if(event.type!=lorkhan::ProtocolEventType::action_intent)return;
                const auto& intent=std::get<lorkhan::ActionIntentEventPayload>(event.payload).intent;
                if(!transferKind(intent.kind)||m_transfers.contains(intent.action.value())||m_transfers.size()>=256)return;
                TransferRecord record;record.intent=std::make_shared<lorkhan::ActionIntent>(intent);
                if(snapshot!=m_transferSnapshots.end())record.snapshot=snapshot->second;
                else record.status="failed",record.reason="observation_unavailable";
                m_transfers.emplace(intent.action.value(),std::move(record));
            }

            void cancelTransfer(const std::string& id)
            {
                const auto found=m_transfers.find(id);if(found==m_transfers.end())return;
                auto& record=found->second;
                if(record.spellHook&&record.status=="pending"){
                    record.status="cancelled";record.reason="cancelled";record.gate.finish();return;
                }
                if((record.status=="pending"||record.status=="awaiting_confirmation")&&record.gate.cancel())record.status="cancelled",record.reason="cancelled";
            }

            sol::table executeTransfer(sol::state_view lua,LuaManager* manager,const std::string& id)
            {
                syncTransferScope();sol::table result(lua,sol::create),observed(lua,sol::create);
                const auto found=m_transfers.find(id);
                if(found==m_transfers.end()){result["status"]="failed";result["reason_code"]="unretained_action";result["observed"]=observed;return result;}
                auto& record=found->second;
                if(record.spellHook&&record.spellStarted&&record.status=="pending"){
                    const auto ptr=transferActorPtr(record.intent->actor);
                    if(ptr.isEmpty()||(!MWBase::Environment::get().getMechanicsManager()->isCastingSpell(ptr)
                        &&!ptr.getClass().getCreatureStats(ptr).getAttackingOrSpell())){
                        record.status="failed";record.reason="cast_interrupted";record.spellHook=false;record.gate.finish();
                    }
                }
                if(record.spellHook&&record.status=="pending"&&parseUtc(record.intent->expiresAt)<=std::chrono::system_clock::now()){
                    record.status="failed";record.reason="action_expired";record.gate.finish();
                }
                if(record.status=="awaiting_confirmation"&&record.gate.queue()){
                    record.status="pending";
                    const auto session=m_transferSession;const auto generation=m_transferGeneration;
                    manager->addAction([this,id,session,generation]{
                        if(!ready()||m_session->value()!=session||this->generation()!=generation)return;
                        const auto found=m_transfers.find(id);if(found==m_transfers.end()||found->second.status!="pending"||!found->second.gate.begin())return;
                        commitTransfer(found->second);if(found->second.status!="pending")found->second.gate.finish();
                    });
                }
                result["status"]=record.status;if(!record.reason.empty())result["reason_code"]=record.reason;
                if(!record.record.empty())observed["record_id"]=record.record;
                if(advancedKind(record.intent->kind)){
                    if(record.count)observed["count"]=record.count;
                    if(record.targetCount)observed["target_count"]=record.targetCount;
                    if(!record.createdIds.empty()){sol::table ids(lua,sol::create);for(const auto& value:record.createdIds)ids.add(value);observed["created_ids"]=ids;}
                    if(!record.destinationCell.empty()){
                        observed["cell"]=record.destinationCell;observed["x"]=record.x;observed["y"]=record.y;observed["z"]=record.z;
                    }
                    if(record.status=="succeeded"){
                        using K=lorkhan::ActionIntentKind;
                        if(record.intent->kind==K::actor_restore)observed["restored"]=true;
                        if(record.intent->kind==K::actor_resurrect)observed["dead"]=false;
                        if(record.intent->kind==K::actor_kill)observed["dead"]=true;
                    }
                }else{
                    if(!record.intent->stringParameter.empty())observed[record.intent->kind==lorkhan::ActionIntentKind::spell_cast?"spell_id":"item_id"]=record.intent->stringParameter;
                    if(record.status=="succeeded"){
                        if(record.intent->kind==lorkhan::ActionIntentKind::spell_cast){observed["cast"]=true;}
                        else if(const auto service=serviceName(record.intent->kind);!service.empty()){observed["service"]=std::string(service);observed["opened"]=true;}
                        else {observed["count"]=record.count;observed["source_count"]=record.sourceCount;observed["target_count"]=record.targetCount;}
                    }
                }
                result["observed"]=observed;return result;
            }

            sol::table transferReceiptStatus(sol::state_view lua,const std::string& id) const
            {
                sol::table result(lua,sol::create);const auto found=m_transfers.find(id);
                if(found==m_transfers.end()){result["status"]="failed";result["reason_code"]="unretained_action";return result;}
                result["status"]=found->second.receiptStatus;
                if(!found->second.receiptReason.empty())result["reason_code"]=found->second.receiptReason;
                return result;
            }

            bool settleTransferReceipt(const lorkhan::InboundResult& result)
            {
                for(auto& [id,record]:m_transfers){
                    if(!record.receiptRequest||*record.receiptRequest!=result.request)continue;
                    record.receiptStatus="failed";record.receiptReason="receipt_transport_failed";
                    if(result.kind==lorkhan::ResponseKind::completed&&record.receipt){
                        auto parsed=lorkhan::parseActionResultAcceptedResponse(result.payload,jsonHeaders());
                        if(parsed&&parsed.value().action.value()==id&&parsed.value().status==record.receipt->status
                            &&parsed.value().correlation.message==record.receipt->message
                            &&parsed.value().correlation.request==record.receipt->correlation.request
                            &&parsed.value().correlation.session==record.receipt->correlation.session
                            &&parsed.value().correlation.generation==record.receipt->correlation.generation
                            &&parsed.value().correlation.turn==record.receipt->turn)
                            record.receiptStatus="accepted",record.receiptReason.clear();
                    }
                    return true;
                }
                return false;
            }

            // The hook stays attached until release, including cancelled animations, to prevent target fallback.
            TransferRecord* pendingSpell(const MWWorld::Ptr& actor)
            {
                for(auto& [id,record]:m_transfers)if(record.spellHook&&record.snapshot)
                    for(const auto& seen:record.snapshot->actors)
                        if(sameTransferActor(seen.identity,record.intent->actor)&&seen.object.ptrOrEmpty()==actor)return &record;
                return nullptr;
            }

            bool spellStartAllowed(const MWWorld::Ptr& actor)
            {
                auto* record=pendingSpell(actor);if(!record)return true;
                if(record->status!="pending"||!ready()||record->snapshot->session!=m_session->value()
                    ||record->snapshot->generation!=generation()||parseUtc(record->intent->expiresAt)<=std::chrono::system_clock::now()
                    ||actor.getClass().getCreatureStats(actor).getSpells().getSelectedSpell().serializeText()!=record->intent->stringParameter){
                    if(record->status=="pending")record->status="failed",record->reason="cast_interrupted",record->gate.finish();
                    record->spellHook=false;return false;
                }
                record->spellStarted=true;return true;
            }

            void spellFinished(const MWWorld::Ptr& actor,bool success,const char* failure="cast_failed")
            {
                auto* record=pendingSpell(actor);if(!record)return;
                if(record->status=="pending"){
                    record->status=success?"succeeded":"failed";record->reason=success?"cast_launched":failure;record->gate.finish();
                }
                record->spellHook=false;
            }

            int spellTarget(const MWWorld::Ptr& actor,MWWorld::Ptr& target)
            {
                auto* record=pendingSpell(actor);if(!record)return 0;
                if(record->status!="pending"||!ready()||record->snapshot->session!=m_session->value()
                    ||record->snapshot->generation!=generation()||!record->spellStarted||record->snapshot->cancelled
                    ||parseUtc(record->intent->expiresAt)<=std::chrono::system_clock::now()
                    ||actor.getClass().getCreatureStats(actor).getSpells().getSelectedSpell().serializeText()!=record->intent->stringParameter){
                    spellFinished(actor,false,"cast_interrupted");return -1;
                }
                const auto& stats=actor.getClass().getCreatureStats(actor);
                if(stats.isDead()||stats.isParalyzed()||stats.getKnockedDown()
                    ||!transferNear(actor,MWBase::Environment::get().getWorld()->getPlayerPtr(),2048)){
                    spellFinished(actor,false,"caster_unavailable");return -1;
                }
                for(const auto& seen:record->snapshot->actors)if(sameTransferActor(seen.identity,record->intent->target))target=seen.object.ptrOrEmpty();
                if(target.isEmpty()||!transferNear(actor,target,2048)||target.getClass().getCreatureStats(target).isDead()
                    ||(target!=actor&&!MWBase::Environment::get().getWorld()->getLOS(actor,target))){
                    spellFinished(actor,false,"target_unavailable");return -1;
                }
                const auto* spell=MWBase::Environment::get().getESMStore()->get<ESM::Spell>().search(ESM::RefId::deserializeText(record->intent->stringParameter));
                if(!spell||!actor.getClass().getCreatureStats(actor).getSpells().hasSpell(spell)){
                    spellFinished(actor,false,"spell_unknown");return -1;
                }
                const double touchRange=std::clamp<double>(MWBase::Environment::get().getESMStore()->get<ESM::GameSetting>().find("fCombatDistance")->mValue.getFloat(),0,2048);
                for(const auto& effect:spell->mEffects.mList)if(effect.mData.mRange==ESM::RT_Touch&&!transferNear(actor,target,touchRange)){
                    spellFinished(actor,false,"out_of_range");return -1;
                }
                if(target!=actor){
                    const auto world=MWBase::Environment::get().getWorld();
                    auto delta=target.getRefData().getPosition().asVec3()-actor.getRefData().getPosition().asVec3();
                    delta.z()+=world->getHalfExtents(target).z()-world->getHalfExtents(actor).z();
                    world->rotateObject(actor,osg::Vec3f(-std::atan2(delta.z(),std::hypot(delta.x(),delta.y())),0,std::atan2(delta.x(),delta.y())));
                }
                return 1;
            }

            static bool advancedRecordAllowed(const TransferSnapshot& snapshot,const std::string& id,bool actor)
            {
                const auto& records=actor?snapshot.advancedActors:snapshot.advancedItems;
                if(std::find(records.begin(),records.end(),id)==records.end())return false;
                if(std::find(snapshot.advancedExactRecords.begin(),snapshot.advancedExactRecords.end(),id)!=snapshot.advancedExactRecords.end())return true;
                MWWorld::ManualRef record(*MWBase::Environment::get().getESMStore(),ESM::RefId::deserializeText(id),1);
                std::string name(record.getPtr().getClass().getName(record.getPtr()));
                std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c){return static_cast<char>(std::tolower(c));});
                const auto& names=actor?snapshot.advancedActorNames:snapshot.advancedItemNames;
                const auto found=names.find(name);return found!=names.end()&&found->second==1;
            }

            // All model mutations resolve only the frozen current player, observed targets and loaded choices.
            void commitAdvanced(TransferRecord& record,const TransferActor* actor,const TransferActor* target,const TransferActor* player)
            {
                using K=lorkhan::ActionIntentKind;const auto& intent=*record.intent;
                record.reason="advanced_precondition_failed";
                if(!record.snapshot->advanced||intent.confirmationRequired!=true||!actor||!target||!player
                    ||actor->identity.kind!="player"||!sameTransferActor(actor->identity,player->identity))return;
                auto world=MWBase::Environment::get().getWorld();
                const auto playerPtr=player->object.ptrOrEmpty(),targetPtr=target->object.ptrOrEmpty();
                if(playerPtr.isEmpty()||targetPtr.isEmpty()||playerPtr!=world->getPlayerPtr()
                    ||!playerPtr.isInCell()||playerPtr.getCell()->getCell()->getId()!=record.snapshot->playerCell
                    ||playerPtr.getClass().getCreatureStats(playerPtr).isDead()||!transferNear(playerPtr,targetPtr,2048))return;
                if((intent.kind==K::actor_spawn||intent.kind==K::gold_create||intent.kind==K::player_teleport)&&targetPtr!=playerPtr)return;
                auto& stats=targetPtr.getClass().getCreatureStats(targetPtr);
                if(intent.kind==K::actor_resurrect){
                    if(targetPtr==playerPtr||!stats.isDead())return;
                    MWBase::Environment::get().getMechanicsManager()->resurrect(targetPtr);
                    if(stats.isDead()){record.reason="resurrection_readback_failed";return;}
                }else if(intent.kind==K::actor_kill){
                    if(targetPtr==playerPtr||stats.isDead())return;
                    auto health=stats.getHealth();health.setCurrent(0);stats.setHealth(health);
                    if(!stats.isDead()){record.reason="death_readback_failed";return;}
                }else{
                    if(stats.isDead())return;
                    if(intent.kind==K::actor_restore){
                        for(int i=0;i<3;++i)if(!std::isfinite(stats.getDynamic(i).getModified())
                            ||stats.getDynamic(i).getModified()<(i==0?1:0))return;
                        for(int i=0;i<3;++i){auto value=stats.getDynamic(i);value.setCurrent(value.getModified());stats.setDynamic(i,value);}
                        for(int i=0;i<3;++i)if(stats.getDynamic(i).getCurrent()!=stats.getDynamic(i).getModified()){
                            record.reason="restore_readback_failed";return;
                        }
                    }else if(intent.kind==K::item_create||intent.kind==K::gold_create){
                        const bool gold=intent.kind==K::gold_create;
                        if(!gold&&!advancedRecordAllowed(*record.snapshot,intent.stringParameter,false)){record.reason="record_not_observed";return;}
                        const auto id=ESM::RefId::deserializeText(gold?"gold_001":intent.stringParameter);
                        const int count=static_cast<int>(intent.transferCount);
                        if(count<1||count>(gold?100000:100))return;
                        MWWorld::ManualRef existing(*MWBase::Environment::get().getESMStore(),id,1);
                        if(!existing.getPtr().getClass().isItem(existing.getPtr()))return;
                        auto& store=targetPtr.getClass().getContainerStore(targetPtr);const int before=store.count(id);
                        if(before<0||before>std::numeric_limits<int>::max()-count)return;
                        store.add(id,count);record.record=id.serializeText();record.count=count;record.targetCount=store.count(id);
                        if(record.targetCount!=before+count){record.reason="creation_readback_failed";return;}
                    }else if(intent.kind==K::actor_spawn){
                        if(!advancedRecordAllowed(*record.snapshot,intent.stringParameter,true)){record.reason="record_not_observed";return;}
                        if(intent.transferCount<1||intent.transferCount>4)return;
                        const auto id=ESM::RefId::deserializeText(intent.stringParameter);
                        MWWorld::ManualRef existing(*MWBase::Environment::get().getESMStore(),id,1);
                        if(existing.getPtr().getType()!=ESM::NPC::sRecordId&&existing.getPtr().getType()!=ESM::Creature::sRecordId)return;
                        record.record=intent.stringParameter;
                        for(std::uint32_t i=0;i<intent.transferCount;++i){
                            const auto created=world->safePlaceObject(existing.getPtr(),playerPtr,playerPtr.getCell(),i,128);
                            if(created.isEmpty()||!created.isInCell()||!created.getClass().isActor()){
                                record.reason="spawn_readback_failed";return;
                            }
                            MWBase::Environment::get().getWorldModel()->registerPtr(created);
                            record.createdIds.push_back(created.getCellRef().getRefNum().toString());++record.count;
                        }
                    }else if(intent.kind==K::actor_teleport_to_player||intent.kind==K::player_teleport){
                        ESM::RefId cell;ESM::Position position{};MWWorld::Ptr moving=targetPtr;
                        if(intent.kind==K::actor_teleport_to_player){
                            if(targetPtr==playerPtr)return;cell=playerPtr.getCell()->getCell()->getId();position=playerPtr.getRefData().getPosition();
                            position.pos[0]+=96;
                        }else{
                            const AdvancedDestination* destination=nullptr;
                            for(const auto& choice:record.snapshot->destinations)if(choice.id==intent.stringParameter)destination=&choice;
                            if(!destination){record.reason="destination_not_observed";return;}
                            cell=destination->cell;position=destination->position;
                            if(destination->actorTarget){
                                const auto seen=destination->actor.ptrOrEmpty();
                                if(seen.isEmpty()||!transferNear(seen,playerPtr,2048)||seen.getClass().getCreatureStats(seen).isDead())return;
                                cell=seen.getCell()->getCell()->getId();position=seen.getRefData().getPosition();position.pos[0]+=96;
                            }
                        }
                        if(moving==playerPtr){
                            MWWorld::ActionTeleport(cell,position,false).execute(moving);moving=world->getPlayerPtr();
                        }else{
                            moving.getClass().getCreatureStats(moving).land(false);
                            moving.getClass().getCreatureStats(moving).setTeleported(true);
                            moving=world->moveObject(moving,&MWBase::Environment::get().getWorldModel()->getCell(cell),position.asVec3(),true,true);
                            MWBase::Environment::get().getLuaManager()->objectTeleported(moving);
                        }
                        world->adjustPosition(moving,false);
                        if(moving.isEmpty()||!moving.isInCell()||moving.getCell()->getCell()->getId()!=cell){record.reason="teleport_readback_failed";return;}
                        const auto actual=moving.getRefData().getPosition();double distance=0;
                        for(int i=0;i<3;++i){const double delta=actual.pos[i]-position.pos[i];distance+=delta*delta;}
                        if(!std::isfinite(distance)||distance>256.0*256.0){record.reason="teleport_readback_failed";return;}
                        record.destinationCell=cell.serializeText();record.x=actual.pos[0];record.y=actual.pos[1];record.z=actual.pos[2];
                    }else return;
                }
                record.status="succeeded";record.reason="advanced_action_completed";
            }

            std::string advancedActionSummary(const std::string& id) const
            {
                const auto found=m_transfers.find(id);if(found==m_transfers.end()||!found->second.snapshot)return {};
                const auto& record=found->second;if(!advancedKind(record.intent->kind))return {};
                if(record.intent->kind==lorkhan::ActionIntentKind::player_teleport){
                    for(const auto& destination:record.snapshot->destinations)if(destination.id==record.intent->stringParameter)
                        return "Destination: "+destination.name+" ("+destination.id+")";
                }
                if(record.intent->kind==lorkhan::ActionIntentKind::item_create||record.intent->kind==lorkhan::ActionIntentKind::actor_spawn){
                    try{MWWorld::ManualRef ref(*MWBase::Environment::get().getESMStore(),ESM::RefId::deserializeText(record.intent->stringParameter),1);
                        return "Create "+std::to_string(record.intent->transferCount)+" x "+std::string(ref.getPtr().getClass().getName(ref.getPtr()))
                            +" ("+record.intent->stringParameter+")";}catch(const std::exception&){return {};}
                }
                using K=lorkhan::ActionIntentKind;
                const auto target=transferActorPtr(record.intent->target);
                const std::string name(target.isEmpty()?record.intent->target.recordId:target.getClass().getName(target));
                if(name.size()>256)return {};
                const auto kind=record.intent->kind;
                if(kind==K::gold_create)return "Create "+std::to_string(record.intent->transferCount)+" gold for "+name;
                if(kind==K::actor_restore)return "Restore health, magicka and fatigue for "+name;
                if(kind==K::actor_resurrect)return "Resurrect "+name+". This may affect quests.";
                if(kind==K::actor_kill)return "Kill "+name+". This may permanently break quests.";
                if(kind==K::actor_teleport_to_player)return "Teleport "+name+" to the player.";
                return {};
            }

            // This action runs on the engine's main-thread action queue exactly once per retained intent.
            void commitTransfer(TransferRecord& record)
            {
                record.status="failed";record.reason="transfer_precondition_failed";
                if(!record.snapshot||record.snapshot->cancelled){record.reason="cancelled";record.status="cancelled";return;}
                if(parseUtc(record.intent->expiresAt)<=std::chrono::system_clock::now()){record.reason="action_expired";return;}
                try{
                    using K=lorkhan::ActionIntentKind;const auto& intent=*record.intent;
                    const TransferActor* actor=nullptr;const TransferActor* target=nullptr;const TransferActor* player=nullptr;
                    for(const auto& observed:record.snapshot->actors){
                        if(sameTransferActor(observed.identity,intent.actor))actor=&observed;
                        if(sameTransferActor(observed.identity,intent.target))target=&observed;
                        if(observed.identity.kind=="player")player=&observed;
                    }
                    if(advancedKind(intent.kind)){commitAdvanced(record,actor,target,player);return;}
                    if(!actor||!target||!player||actor->identity.kind=="player")return;
                    const auto actorPtr=actor->object.ptrOrEmpty();const auto targetPtr=target->object.ptrOrEmpty();
                    const auto playerPtr=player->object.ptrOrEmpty();
                    if(actorPtr.isEmpty()||targetPtr.isEmpty()||playerPtr.isEmpty()
                        ||actorPtr.getClass().getCreatureStats(actorPtr).isDead()
                        ||targetPtr.getClass().getCreatureStats(targetPtr).isDead()
                        ||!transferNear(actorPtr,playerPtr,2048))return;
                    if(intent.kind==K::spell_cast){
                        auto& stats=actorPtr.getClass().getCreatureStats(actorPtr);
                        const auto mechanics=MWBase::Environment::get().getMechanicsManager();
                        if(stats.isParalyzed()||stats.getKnockedDown()||mechanics->isCastingSpell(actorPtr)
                            ||stats.getAttackingOrSpell()||pendingSpell(actorPtr)){record.reason="actor_busy";return;}
                        if(!transferNear(actorPtr,targetPtr,2048)){record.reason="out_of_range";return;}
                        if(std::find(actor->spells.begin(),actor->spells.end(),intent.stringParameter)==actor->spells.end()
                            ||!stats.getSpells().hasSpell(ESM::RefId::deserializeText(intent.stringParameter))){record.reason="spell_unknown";return;}
                        record.spellHook=true;record.status="pending";record.reason.clear();
                        mechanics->castSpell(actorPtr,ESM::RefId::deserializeText(intent.stringParameter),false);
                        return;
                    }
                    if(const auto service=serviceName(intent.kind);!service.empty()){
                        if(target->identity.kind!="player"||targetPtr!=playerPtr)return;
                        if(!transferNear(actorPtr,playerPtr,256)){record.reason="out_of_range";return;}
                        const auto offered=offeredServices(actorPtr);
                        if(std::find(actor->services.begin(),actor->services.end(),service)==actor->services.end()
                            ||std::find(offered.begin(),offered.end(),service)==offered.end()){record.reason="service_unavailable";return;}
                        const auto windows=MWBase::Environment::get().getWindowManager();
                        if(windows->isGuiMode()&&windows->getMode()!=MWGui::GM_Dialogue){record.reason="menu_busy";return;}
                        auto activation=actorPtr.getClass().activate(actorPtr,playerPtr);
                        if(!dynamic_cast<MWWorld::ActionTalk*>(activation.get())){record.reason="activation_refused";return;}
                        if(!windows->isGuiMode())activation->execute(playerPtr);
                        using D=MWBase::DialogueManager;D::ServiceType type=D::Any;
                        switch(intent.kind){
                            case K::service_barter:type=D::Barter;break;
                            case K::service_training:type=D::Training;break;
                            case K::service_spells:type=D::Spells;break;
                            case K::service_travel:type=D::Travel;break;
                            case K::service_spellmaking:type=D::Spellmaking;break;
                            case K::service_enchanting:type=D::Enchanting;break;
                            case K::service_repair:type=D::Repair;break;
                            default:break;
                        }
                        for(auto* window:windows->getGuiModeWindows(MWGui::GM_Dialogue)){
                            if(auto* dialogue=dynamic_cast<MWGui::DialogueWindow*>(window)){
                                const auto outcome=dialogue->selectLorkhanService(actorPtr,type);
                                if(outcome=="opened"){record.status="succeeded";record.reason="opened";}
                                else record.reason=outcome;
                                return;
                            }
                        }
                        record.reason="dialogue_unavailable";return;
                    }
                    const bool take=intent.kind==K::item_take||intent.kind==K::gold_take;
                    const bool pickup=intent.kind==K::item_pickup;
                    const bool gold=intent.kind==K::gold_give||intent.kind==K::gold_take;
                    if(take&&target->identity.kind!="player")return;
                    const auto source=take?playerPtr:actorPtr;const auto recipient=take?actorPtr:targetPtr;
                    if(!pickup&&(source==recipient||!transferNear(source,recipient,256))){record.reason="out_of_range";return;}
                    auto& destinationStore=recipient.getClass().getContainerStore(recipient);
                    if(gold){
                        const auto sourceObservation=take?player:actor;const int amount=static_cast<int>(intent.transferCount);
                        auto& sourceStore=source.getClass().getContainerStore(source);
                        const auto goldId=ESM::RefId::stringRefId("gold_001");
                        const int sourceBefore=sourceStore.count(goldId),targetBefore=destinationStore.count(goldId);
                        if(amount<1||amount>100000||sourceBefore!=sourceObservation->gold||sourceObservation->observedGold<amount
                            ||sourceBefore<amount||targetBefore<0||targetBefore>std::numeric_limits<int>::max()-amount)return;
                        auto added=*destinationStore.add(goldId,amount,false);
                        if(sourceStore.remove(goldId,amount)!=amount){destinationStore.remove(added,amount);return;}
                        record.record="gold_001";record.count=amount;record.sourceCount=sourceStore.count(goldId);
                        record.targetCount=destinationStore.count(goldId);
                        if(record.sourceCount!=sourceBefore-amount||record.targetCount!=targetBefore+amount){record.reason="transfer_readback_failed";return;}
                    }else{
                        const TransferItem* item=nullptr;for(const auto& observed:record.snapshot->items)
                            if(observed.id==intent.stringParameter){item=&observed;break;}
                        if(!item)return;const auto ptr=item->object.ptrOrEmpty();
                        if(ptr.isEmpty()||!ptr.getClass().isItem(ptr)||ptr.getCellRef().getRefId().serializeText()!=item->record
                            ||ptr.getCellRef().getCount()!=item->count)return;
                        if(pickup){
                            if(item->location!="ground"||!transferNear(actorPtr,ptr,256)){record.reason="out_of_range";return;}
                            const std::int64_t quantity=static_cast<std::int64_t>(item->count)*(ptr.getClass().isGold(ptr)?ptr.getClass().getValue(ptr):1);
                            if(quantity<1||quantity>std::numeric_limits<int>::max())return;
                            auto& actorStore=actorPtr.getClass().getContainerStore(actorPtr);
                            const auto outputId=ptr.getClass().isGold(ptr)?ESM::RefId::stringRefId("gold_001"):ptr.getCellRef().getRefId();
                            const int before=actorStore.count(outputId);if(before<0||before>std::numeric_limits<int>::max()-quantity)return;
                            MWWorld::ActionTake action(ptr);action.execute(actorPtr,true);
                            record.record=outputId.serializeText();record.count=static_cast<int>(quantity);
                            record.sourceCount=ptr.getCellRef().getCount();record.targetCount=actorStore.count(outputId);
                            if(record.sourceCount!=0||record.targetCount!=before+quantity){record.reason="transfer_readback_failed";return;}
                        }else{
                            auto& sourceStore=source.getClass().getContainerStore(source);
                            if(item->location!=(take?"player_inventory":"actor_inventory")
                                ||item->owner.ptrOrEmpty()!=source||ptr.getContainerStore()!=&sourceStore)return;
                            const int amount=static_cast<int>(intent.transferCount);
                            if(amount<1||amount>1000||amount>item->count||(ptr.getClass().isGold(ptr)&&item->record!="gold_001"))return;
                            const auto recordId=ptr.getCellRef().getRefId();const int sourceBefore=sourceStore.count(recordId);
                            const int targetBefore=destinationStore.count(recordId);if(sourceBefore<amount||targetBefore<0||targetBefore>std::numeric_limits<int>::max()-amount)return;
                            auto added=*destinationStore.add(ptr,amount,false);
                            if(sourceStore.remove(ptr,amount)!=amount){destinationStore.remove(added,amount);return;}
                            record.record=item->record;record.count=amount;record.sourceCount=sourceStore.count(recordId);
                            record.targetCount=destinationStore.count(recordId);
                            if(record.sourceCount!=sourceBefore-amount||record.targetCount!=targetBefore+amount){record.reason="transfer_readback_failed";return;}
                        }
                    }
                    record.status="succeeded";record.reason="completed";
                }catch(const std::exception&){record.reason="transfer_engine_error";}
            }

            std::tuple<sol::object, sol::object> submitActorProfile(sol::state_view lua, sol::table payload)
            {
                try
                {
                    const auto identity = lorkhan::parseProtocolIdentity(toJson(payload.get<sol::object>("actor")));
                    if (!identity || (identity.value().kind != "npc" && identity.value().kind != "creature"))
                        return failure(lua, "invalid_actor_profile");
                    const auto& expected = identity.value();
                    MWWorld::Ptr ptr;
                    if (expected.refnumIndex <= std::numeric_limits<std::uint32_t>::max()
                        && expected.refnumContentFile <= static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max()))
                        ptr = MWBase::Environment::get().getWorldModel()->getPtr(ESM::RefNum{
                            static_cast<std::uint32_t>(expected.refnumIndex), static_cast<std::int32_t>(expected.refnumContentFile)});
                    // Unloaded references stay unknown; never resolve a different copy by record ID.
                    const bool matched = !ptr.isEmpty()
                        && ptr.getCellRef().getRefId().serializeText() == expected.recordId
                        && ptr.getType() == (expected.kind == "creature" ? ESM::Creature::sRecordId : ESM::NPC::sRecordId);
                    auto provenance = recordProvenanceTable(lua, matched ? ptr : MWWorld::Ptr());
                    provenance["record_id"] = expected.recordId;
                    payload["record_provenance"] = provenance;
                    return submitGameData(lua, lorkhan::GameDataType::actor_profile, std::move(payload));
                }
                catch (const std::exception& error) { return failure(lua, error.what()); }
            }

            std::tuple<sol::object, sol::object> submitAutomaticDiary(sol::state_view lua, sol::table payload)
            {
                return submitGameData(lua, lorkhan::GameDataType::automatic_diary, std::move(payload));
            }

            std::tuple<sol::object, sol::object> requestControls(sol::state_view lua, sol::table target)
            {
                if (!ready()) return failure(lua, "bridge_not_ready");
                if (m_controlsRequest) return failure(lua, "controls_request_pending");
                try {
                    const lorkhan::RequestId request(uuid());
                    const lorkhan::MessageId message(uuid());
                    lorkhan::OutboundRequest outbound{request,*m_session,m_service->generation(),
                        lorkhan::RequestKind::controls_query,lorkhan::ControlsQueryRequest{message,
                            {request,*m_session,m_service->generation()},toJson(sol::make_object(lua,target))}};
                    auto accepted=m_service->enqueue(std::move(outbound));
                    if(!accepted)return failure(lua,accepted.error().message);
                    m_controlsRequest=request;m_controlsError.clear();
                    return success(lua,request.value());
                }
                catch(const std::exception& error){return failure(lua,error.what());}
            }

            std::tuple<sol::object, sol::object> selectControl(sol::state_view lua,const std::string& kind,
                sol::optional<std::string> selection,sol::table target)
            {
                if (!ready()) return failure(lua, "bridge_not_ready");
                if (m_controlsRequest) return failure(lua, "controls_request_pending");
                try {
                    const auto mapped=kind=="model_slot"?lorkhan::SessionControlKind::model_slot
                        :kind=="actor_profile"?lorkhan::SessionControlKind::actor_profile
                        :kind=="profile_generate"?lorkhan::SessionControlKind::profile_generate
                        :kind=="narrator_profile_generate"?lorkhan::SessionControlKind::narrator_profile_generate
                        :throw std::runtime_error("invalid_session_control_kind");
                    const bool semanticModel= mapped==lorkhan::SessionControlKind::model_slot;
                    if(semanticModel&&(!selection||(*selection!="standard"&&*selection!="fast"
                        &&*selection!="powerful"&&*selection!="experimental")))
                        throw std::runtime_error("invalid_session_control_selection");
                    if(!semanticModel&&selection&&!lorkhan::isCanonicalUuid(*selection))
                        throw std::runtime_error("invalid_session_control_selection");
                    const lorkhan::RequestId request(uuid());const lorkhan::MessageId message(uuid());
                    lorkhan::OutboundRequest outbound{request,*m_session,m_service->generation(),
                        lorkhan::RequestKind::controls_select,lorkhan::ControlsSelectRequest{message,
                            {request,*m_session,m_service->generation()},utcNow(),mapped,
                            semanticModel?std::nullopt:(selection?std::optional<std::string>(*selection):std::nullopt),
                            semanticModel?std::optional<std::string>(*selection):std::nullopt,toJson(sol::make_object(lua,target))}};
                    auto accepted=m_service->enqueue(std::move(outbound));
                    if(!accepted)return failure(lua,accepted.error().message);
                    m_controlsRequest=request;m_controlsError.clear();
                    return success(lua,request.value());
                }
                catch(const std::exception& error){return failure(lua,error.what());}
            }

            void cancelDiaryBook()
            {
                ++m_diarySerial;
                if(m_service){if(m_diaryRequest)(void)m_service->cancel(*m_diaryRequest);
                    if(m_diaryReceipt)(void)m_service->cancel(*m_diaryReceipt);}
                m_diaryRequest.reset();m_diaryReceipt.reset();m_diaryBook.reset();m_diaryReceiptDto.reset();m_diaryPending=false;
                m_diaryState.clear();m_diaryReason.clear();m_diaryError.clear();m_diaryReceiptOk=false;
            }

            std::tuple<sol::object,sol::object> requestDiaryBook(sol::state_view lua)
            {
                if(!ready())return failure(lua,"not_ready");
                if(m_diaryRequest||m_diaryReceipt||m_diaryPending)return failure(lua,"diary_request_pending");
                try {
                    lorkhan::RequestId request(uuid());lorkhan::MessageId message(uuid());
                    lorkhan::OutboundRequest outbound{request,*m_session,m_service->generation(),
                        lorkhan::RequestKind::diary_book_query,lorkhan::DiaryBookQueryRequest{message,
                            {request,*m_session,m_service->generation()}}};
                    auto sent=m_service->enqueue(std::move(outbound));if(!sent)return failure(lua,sent.error().message);
                    m_diaryRequest=request;m_diaryBook.reset();m_diaryReceiptDto.reset();m_diaryError.clear();m_diaryState.clear();
                    return success(lua,request.value());
                }catch(const std::exception& e){return failure(lua,e.what());}
            }

            bool settleDiaryResult(const lorkhan::InboundResult& result)
            {
                if(m_diaryRequest&&result.request==*m_diaryRequest){
                    m_diaryRequest.reset();m_diaryBook.reset();
                    if(result.kind==lorkhan::ResponseKind::diary_book){
                        auto parsed=lorkhan::parseDiaryBookResponse(result.payload,jsonHeaders());
                        if(parsed)m_diaryBook=std::move(parsed).value().book;
                        else m_diaryError=parsed.error().message;
                    }else m_diaryError="diary_query_failed";
                    return true;
                }
                if(m_diaryReceipt&&result.request==*m_diaryReceipt){
                    m_diaryReceipt.reset();m_diaryReceiptOk=result.kind==lorkhan::ResponseKind::completed;
                    if(!m_diaryReceiptOk)m_diaryError="diary_receipt_failed";
                    return true;
                }
                return false;
            }

            sol::table pumpDiaryBook(sol::state_view lua,bool receipt=false)
            {
                if(m_service&&(m_diaryRequest||m_diaryReceipt)&&m_deferredResults.size()+kControlsPumpBatch<=kDeferredResultCapacity){
                    for(auto& result:m_service->poll(kControlsPumpBatch)){
                        if(settleDiaryResult(result)){++m_resultsSeen;continue;}
                        m_deferredResults.push_back(std::move(result));
                    }
                }
                sol::table result(lua,sol::create);result["pending"]=receipt?m_diaryReceipt.has_value():m_diaryRequest.has_value();
                if(!m_diaryError.empty())result["error"]=m_diaryError;
                if(receipt)result["ok"]=m_diaryReceiptOk;
                else if(m_diaryBook){sol::table book(lua,sol::create);
                    book["delivery_id"]=m_diaryBook->delivery.value();book["book_id"]=m_diaryBook->book.value();
                    book["target"]=identityTable(lua,m_diaryBook->target);book["title"]=m_diaryBook->title;
                    book["content"]=m_diaryBook->content;book["content_hash"]=m_diaryBook->contentHash;result["book"]=book;}
                return result;
            }

            // A retained authenticated DTO is the only source of book content and recipient identity.
            std::tuple<sol::object,sol::object> materializeDiaryBook(sol::state_view lua,LuaManager* manager,
                const GObject& actor,const std::string& delivery)
            {
                if(!ready()||!m_diaryBook||m_diaryBook->delivery.value()!=delivery)return failure(lua,"invalid_payload");
                if(m_diaryPending||!m_diaryState.empty())return success(lua,delivery);
                const auto book=*m_diaryBook;const auto scope=*observationScope();const auto serial=m_diarySerial;
                m_diaryPending=true;m_diaryReason.clear();
                manager->addAction([this,actor,book,scope,serial] {
                    if(serial!=m_diarySerial||!ready()||m_session->value()!=scope.sessionId||generation()!=scope.generation)return;
                    m_diaryPending=false;m_diaryState="failed";m_diaryReason="record_creation_failed";
                    try {
                        const auto& recipient=actor.ptr();const auto& ref=recipient.getCellRef().getRefNum();
                        const bool creature=recipient.getType()==ESM::Creature::sRecordId;
                        if((!creature&&recipient.getType()!=ESM::NPC::sRecordId)
                            ||book.target.kind!=(creature?"creature":"npc")
                            ||recipient.getCellRef().getRefId().serializeText()!=book.target.recordId
                            ||ref.mIndex!=book.target.refnumIndex||ref.mContentFile!=book.target.refnumContentFile){
                            m_diaryReason="target_mismatch";return;}
                        if(recipient.getCellRef().getCount()<=0){m_diaryReason="target_unavailable";return;}
                        auto store=MWBase::Environment::get().getESMStore();
                        auto& books=store->getWritable<ESM::Book>();
                        const auto id=ESM::RefId::stringRefId("lorkhan_diary_"+book.book.value());
                        const auto* existing=books.search(id);
                        const std::string marker="<!-- LORKHAN diary "+book.book.value()+" -->";
                        if((!existing&&store->find(id)!=0)||(existing&&(!books.isDynamic(id)
                            ||!existing->mScript.empty()||!existing->mEnchant.empty()||existing->mData.mSkillId!=-1
                            ||existing->mData.mValue!=0||existing->mText.rfind(marker,0)!=0))){
                            m_diaryReason="book_unavailable";return;}
                        ESM::Book record;record.blank();record.mId=id;record.mName=book.title;
                        record.mData.mWeight=1.f;record.mData.mSkillId=-1;
                        if(existing){record.mModel=existing->mModel;record.mIcon=existing->mIcon;}
                        else {
                            // Use a mundane installed book's assets, never an asset path from the server.
                            for(const auto& candidate:books){
                                if(!books.isDynamic(candidate.mId)&&!candidate.mModel.empty()&&!candidate.mIcon.empty()
                                    &&candidate.mData.mIsScroll==0&&candidate.mScript.empty()&&candidate.mEnchant.empty()){
                                    record.mModel=candidate.mModel;record.mIcon=candidate.mIcon;break;}
                            }
                            if(record.mModel.empty()){m_diaryReason="book_unavailable";return;}
                        }
                        record.mText=marker;
                        for(char c:book.content){switch(c){case '&':record.mText+='&';break;
                            case '<':record.mText+='[';break;case '>':record.mText+=']';break;
                            case '%':record.mText+="%<!-- -->";break;case '^':record.mText+="^<!-- -->";break;
                            case '\n':record.mText+="<BR>";break;case '\r':break;default:record.mText+=c;}}
                        record.mText+="<BR>"; // TES3 book layout hides text beyond its final paragraph tag.
                        if(existing&&existing->mText==record.mText&&existing->mName==record.mName){
                            m_diaryState="succeeded";m_diaryReason.clear();return;}
                        // Dynamic records are serialized by ESMStore and survive dropping, trading and save/load.
                        store->overrideRecord(record);
                        if(!existing){
                            try {MWWorld::ManualRef item(*store,id);
                                recipient.getClass().getContainerStore(recipient).add(item.getPtr(),1,false);}
                            catch(...){books.erase(id);m_diaryReason="inventory_update_failed";return;}
                        }
                        m_diaryState="succeeded";m_diaryReason.clear();
                    }catch(const std::exception&){/* Return bounded failure without leaking game paths. */}
                });
                return success(lua,delivery);
            }

            sol::table diaryBookStatus(sol::state_view lua,const std::string& delivery) const
            {
                sol::table result(lua,sol::create);result["pending"]=m_diaryPending;
                if(!m_diaryBook||m_diaryBook->delivery.value()!=delivery){result["status"]="failed";result["reason_code"]="invalid_payload";}
                else {if(!m_diaryState.empty())result["status"]=m_diaryState;if(!m_diaryReason.empty())result["reason_code"]=m_diaryReason;}
                return result;
            }

            std::tuple<sol::object,sol::object> submitDiaryBookResult(sol::state_view lua,const std::string& delivery,
                const std::string& status,sol::optional<std::string> reason)
            {
                if(!ready()||!m_diaryBook||m_diaryBook->delivery.value()!=delivery)return failure(lua,"invalid_payload");
                if(m_diaryReceipt)return failure(lua,"diary_receipt_pending");
                if(status!="succeeded"&&status!="failed")return failure(lua,"invalid_payload");
                if(m_diaryPending||(status=="succeeded"&&m_diaryState!="succeeded"))return failure(lua,"invalid_payload");
                if(!m_diaryState.empty()&&(status!=m_diaryState||reason.value_or("")!=m_diaryReason))return failure(lua,"invalid_payload");
                try {lorkhan::RequestId request(uuid());lorkhan::MessageId message(uuid());
                    if(!m_diaryReceiptDto)m_diaryReceiptDto=lorkhan::DiaryBookResultRequest{message,{request,*m_session,m_service->generation()},m_diaryBook->delivery,
                        m_diaryBook->book,m_diaryBook->contentHash,status=="succeeded"?lorkhan::DebugCommandResultStatus::succeeded
                        :lorkhan::DebugCommandResultStatus::failed,reason.value_or(""),utcNow()};
                    if(m_diaryReceiptDto->reasonCode!=reason.value_or("")
                        ||(m_diaryReceiptDto->status==lorkhan::DebugCommandResultStatus::succeeded)!=(status=="succeeded"))return failure(lua,"invalid_payload");
                    auto receipt=*m_diaryReceiptDto;receipt.correlation.request=request;
                    lorkhan::OutboundRequest outbound{request,*m_session,m_service->generation(),lorkhan::RequestKind::diary_book_result,std::move(receipt)};
                    auto sent=m_service->enqueue(std::move(outbound));if(!sent)return failure(lua,sent.error().message);
                    m_diaryReceipt=request;m_diaryReceiptOk=false;m_diaryError.clear();return success(lua,request.value());
                }catch(const std::exception& e){return failure(lua,e.what());}
            }

            std::tuple<sol::object,sol::object> requestDebugCommand(sol::state_view lua)
            {
                if(!ready())return failure(lua,"bridge_not_ready");
                if(m_debugRequest)return failure(lua,"debug_request_pending");
                try{
                    const lorkhan::RequestId request(uuid());const lorkhan::MessageId message(uuid());
                    lorkhan::OutboundRequest outbound{request,*m_session,m_service->generation(),
                        lorkhan::RequestKind::debug_command_query,lorkhan::DebugCommandQueryRequest{message,
                            {request,*m_session,m_service->generation()}}};
                    auto accepted=m_service->enqueue(std::move(outbound));if(!accepted)return failure(lua,accepted.error().message);
                    m_debugRequest=request;m_debugCommand.reset();m_debugError.clear();return success(lua,request.value());
                }catch(const std::exception& error){return failure(lua,error.what());}
            }

            std::tuple<sol::object,sol::object> submitDebugCommandResult(sol::state_view lua,const std::string& commandId,
                const std::string& status,const std::string& reason,sol::table observed)
            {
                if(!ready())return failure(lua,"bridge_not_ready");
                try{
                    const auto mapped=status=="succeeded"?lorkhan::DebugCommandResultStatus::succeeded
                        :status=="failed"?lorkhan::DebugCommandResultStatus::failed
                        :status=="rejected"?lorkhan::DebugCommandResultStatus::rejected
                        :throw std::runtime_error("invalid_debug_result_status");
                    const lorkhan::RequestId request(uuid());const lorkhan::MessageId message(uuid());
                    lorkhan::OutboundRequest outbound{request,*m_session,m_service->generation(),
                        lorkhan::RequestKind::debug_command_result,lorkhan::DebugCommandResultRequest{message,
                            {request,*m_session,m_service->generation()},lorkhan::MessageId(commandId),mapped,reason,
                            toJson(sol::make_object(lua,observed)),utcNow()}};
                    auto accepted=m_service->enqueue(std::move(outbound));if(!accepted)return failure(lua,accepted.error().message);
                    return success(lua,request.value());
                }catch(const std::exception& error){return failure(lua,error.what());}
            }

            sol::object sessionControls(sol::state_view lua) const
            {
                if(!m_controls)return sol::make_object(lua,sol::nil);
                sol::table result(lua,sol::create),slots(lua,sol::create),profiles(lua,sol::create);
                result["target"]=identityTable(lua,m_controls->target);
                result["selected_model_slot_key"]=m_controls->selectedModelSlotKey;
                if(m_controls->resolvedModelSlotKey)result["resolved_model_slot_key"]=*m_controls->resolvedModelSlotKey;
                if(m_controls->selectedProfileId)result["selected_profile_id"]=*m_controls->selectedProfileId;
                if(m_controls->narratorProfileId)result["narrator_profile_id"]=*m_controls->narratorProfileId;
                const auto& snapshot=m_controls->effectiveSettings;
                sol::table effective(lua,sol::create),settings(lua,sol::create),memory(lua,sol::create),narrator(lua,sol::create);
                sol::table behavior(lua,sol::create),safety(lua,sol::create),routing(lua,sol::create),sources(lua,sol::create);
                effective["schema"]=snapshot.schema;effective["change_token"]=snapshot.changeToken;
                if(snapshot.profileId)effective["profile_id"]=*snapshot.profileId;
                if(snapshot.profileRevision)effective["profile_revision"]=*snapshot.profileRevision;
                if(snapshot.coreProfileId)effective["core_profile_id"]=*snapshot.coreProfileId;
                if(snapshot.coreProfileRevision)effective["core_profile_revision"]=*snapshot.coreProfileRevision;
                behavior["auto_greeting"]=snapshot.behavior.autoGreeting;
                behavior["rechat"]=snapshot.behavior.rechat;behavior["rechat_max_depth"]=snapshot.behavior.rechatMaxDepth;
                behavior["rechat_probability_percent"]=snapshot.behavior.rechatProbabilityPercent;
                behavior["rechat_mode"]=snapshot.behavior.rechatMode;behavior["rechat_strict_targeting"]=snapshot.behavior.rechatStrictTargeting;
                behavior["open_rechat"]=snapshot.behavior.openRechat;
                behavior["end_conversation_cooldown_seconds"]=snapshot.behavior.endConversationCooldownSeconds;
                behavior["boredom"]=snapshot.behavior.boredom;behavior["boredom_delay_seconds"]=snapshot.behavior.boredomDelaySeconds;
                behavior["combat_barks"]=snapshot.behavior.combatBarks;
                behavior["ai_enabled"]=snapshot.behavior.aiEnabled;
                behavior["combat_bark_period_seconds"]=snapshot.behavior.combatBarkPeriodSeconds;
                memory["recent_turn_limit"]=snapshot.memory.recentTurnLimit;memory["knowledge_limit"]=snapshot.memory.knowledgeLimit;
                narrator["enabled"]=snapshot.narrator.enabled;narrator["name"]=snapshot.narrator.name;
                narrator["context_visibility"]=snapshot.narrator.contextVisibility;narrator["inline_mode"]=snapshot.narrator.inlineMode;
                narrator["welcome_events"]=snapshot.narrator.welcomeEvents;
                narrator["welcome_cooldown_minutes"]=snapshot.narrator.welcomeCooldownMinutes;
                narrator["random_events"]=snapshot.narrator.randomEvents;
                narrator["random_chance_percent"]=snapshot.narrator.randomChancePercent;
                narrator["random_cooldown_rounds"]=snapshot.narrator.randomCooldownRounds;
                narrator["bored_events"]=snapshot.narrator.boredEvents;
                narrator["bored_chance_percent"]=snapshot.narrator.boredChancePercent;
                narrator["quest_events"]=snapshot.narrator.questEvents;
                narrator["quest_chance_percent"]=snapshot.narrator.questChancePercent;
                narrator["quest_cooldown_minutes"]=snapshot.narrator.questCooldownMinutes;
                narrator["book_events"]=snapshot.narrator.bookEvents;
                safety["actions_enabled"]=snapshot.safety.actionsEnabled;safety["allow_hostile"]=snapshot.safety.allowHostile;
                safety["allow_creatures"]=snapshot.safety.allowCreatures;
                settings["behavior"]=behavior;settings["memory"]=memory;settings["narrator"]=narrator;settings["safety"]=safety;
                for(const auto&[key,value]:snapshot.routing){if(const auto* text=std::get_if<std::string>(&value))routing[key]=*text;
                    else routing[key]=std::get<bool>(value);}
                for(const auto&[key,source]:snapshot.sourceMap)sources[key]=source;
                effective["settings"]=settings;effective["routing"]=routing;effective["source_map"]=sources;
                result["effective_settings"]=effective;
                for(std::size_t index=0;index<m_controls->modelSlots.size();++index){const auto& slot=m_controls->modelSlots[index];
                    sol::table row(lua,sol::create);row["key"]=slot.key;row["label"]=slot.label;row["available"]=slot.available;
                    if(slot.configurationId)row["configuration_id"]=*slot.configurationId;
                    if(slot.configurationName)row["configuration_name"]=*slot.configurationName;
                    if(slot.revision)row["revision"]=*slot.revision;if(slot.driver)row["driver"]=*slot.driver;
                    if(slot.model)row["model"]=*slot.model;slots[index+1]=row;}
                for(std::size_t index=0;index<m_controls->profiles.size();++index){const auto& profile=m_controls->profiles[index];
                    sol::table row(lua,sol::create);row["profile_id"]=profile.profileId;row["name"]=profile.name;
                    row["revision"]=profile.revision;profiles[index+1]=row;}
                result["model_slots"]=slots;result["profiles"]=profiles;result["pending"]=m_controlsRequest.has_value();
                return sol::make_object(lua,result);
            }

            std::tuple<sol::object, sol::object> prepareMedia(sol::state_view lua, sol::table dto)
            {
                if (!ready()) return failure(lua, "bridge_not_ready");
                try
                {
                    const std::string mediaId = dto.get<std::string>("media_id");
                    const std::string hash = dto.get<std::string>("sha256");
                    const std::string codecName = dto.get<std::string>("codec");
                    const lorkhan::MediaCodec codec = codecName == "wav" ? lorkhan::MediaCodec::wav
                        : codecName == "ogg" ? lorkhan::MediaCodec::ogg : codecName == "mp3" ? lorkhan::MediaCodec::mp3
                        : throw std::runtime_error("unsupported media codec");
                    lorkhan::MediaDescriptor descriptor{ lorkhan::MediaId(mediaId), parseSha256(hash),
                        dto.get<std::size_t>("bytes"), codec, parseUtc(dto.get<std::string>("expires_at")) };
                    const lorkhan::RequestId request(uuid());
                    lorkhan::OutboundRequest outbound{ request, *m_session, m_service->generation(), lorkhan::RequestKind::media,
                        lorkhan::MediaPrepareRequest{ { request, *m_session, m_service->generation() }, descriptor } };
                    auto accepted = m_service->enqueue(std::move(outbound));
                    if (!accepted) return failure(lua, accepted.error().message);
                    const std::string extension = codec == lorkhan::MediaCodec::wav ? ".wav"
                        : codec == lorkhan::MediaCodec::ogg ? ".ogg" : ".mp3";
                    m_media[mediaId] = { "preparing",
                        m_config->cacheRoot / hash.substr(0, 2) / (hash + extension), {}, request };
                    return success(lua, request.value());
                }
                catch (const std::exception& error) { return failure(lua, error.what()); }
            }

            std::tuple<sol::object, sol::object> requestMenuDialogueTts(
                sol::state_view lua, sol::table actor, const std::string& text)
            {
                if(!ready())return failure(lua,"bridge_not_ready");
                try{
                    if(text.empty()||text.size()>16U*1024U)throw std::runtime_error("invalid_menu_dialogue_text");
                    if(m_pollRequest){static_cast<void>(m_service->cancel(*m_pollRequest));m_pollRequest.reset();}
                    const lorkhan::RequestId request(uuid());const lorkhan::MessageId message(uuid());
                    lorkhan::OutboundRequest outbound{request,*m_session,m_service->generation(),
                        lorkhan::RequestKind::menu_dialogue_tts,lorkhan::MenuDialogueTtsRequest{message,
                            {request,*m_session,m_service->generation()},utcNow(),
                            toJson(sol::make_object(lua,actor)),text}};
                    auto accepted=m_service->enqueue(std::move(outbound));
                    if(!accepted)return failure(lua,accepted.error().message);
                    m_menuDialogues.emplace(request.value(),MenuDialogueState{"requesting",{},request,{}});
                    return success(lua,request.value());
                }catch(const std::exception& error){return failure(lua,error.what());}
            }

            bool cancelMenuDialogueTts(const std::optional<std::string>& requestId=std::nullopt)
            {
                bool cancelled=false;
                for(auto iterator=m_menuDialogues.begin();iterator!=m_menuDialogues.end();){
                    if(requestId&&iterator->first!=*requestId){++iterator;continue;}
                    auto& dialogue=iterator->second;
                    if(dialogue.request&&m_service)static_cast<void>(m_service->cancel(*dialogue.request));
                    const auto mediaId=dialogue.media
                        ?std::optional<std::string>(dialogue.media->media.value()):std::nullopt;
                    iterator=m_menuDialogues.erase(iterator);cancelled=true;
                    if(mediaId){
                        const bool stillUsed=std::any_of(m_menuDialogues.begin(),m_menuDialogues.end(),[&](const auto& item){
                            return item.second.media&&item.second.media->media.value()==*mediaId;});
                        if(!stillUsed){
                            const auto found=m_media.find(*mediaId);
                            if(found!=m_media.end()&&found->second.request&&m_service)
                                static_cast<void>(m_service->cancel(*found->second.request));
                            m_media.erase(*mediaId);
                        }
                    }
                    if(requestId)break;
                }
                return cancelled;
            }

            sol::object menuDialogueTtsStatus(sol::state_view lua,const std::string& requestId) const
            {
                const auto found=m_menuDialogues.find(requestId);
                if(found==m_menuDialogues.end())return sol::make_object(lua,sol::nil);
                const auto& dialogue=found->second;
                sol::table result(lua,sol::create);result["state"]=dialogue.state;
                if(!dialogue.reason.empty())result["reason"]=dialogue.reason;
                if(dialogue.media)result["media_id"]=dialogue.media->media.value();
                return sol::make_object(lua,result);
            }

            std::tuple<sol::object, sol::object> requestPlayerAutochat(sol::state_view lua,
                sol::table player,sol::table target,const std::string& intent)
            {
                if(!ready())return failure(lua,"bridge_not_ready");
                try{
                    if(intent.empty()||intent.size()>16U*1024U)throw std::runtime_error("invalid_player_autochat_intent");
                    if(!m_playerAutochats.empty())return failure(lua,"player_autochat_busy");
                    if(m_pollRequest){static_cast<void>(m_service->cancel(*m_pollRequest));m_pollRequest.reset();}
                    const lorkhan::RequestId request(uuid());const lorkhan::MessageId message(uuid());
                    lorkhan::OutboundRequest outbound{request,*m_session,m_service->generation(),
                        lorkhan::RequestKind::player_autochat,lorkhan::PlayerAutochatRequest{message,
                            {request,*m_session,m_service->generation()},utcNow(),
                            toJson(sol::make_object(lua,player)),toJson(sol::make_object(lua,target)),intent}};
                    auto accepted=m_service->enqueue(std::move(outbound));
                    if(!accepted)return failure(lua,accepted.error().message);
                    m_playerAutochats.emplace(request.value(),PlayerAutochatState{"requesting",{}, {},request});
                    return success(lua,request.value());
                }catch(const std::exception& error){return failure(lua,error.what());}
            }

            bool cancelPlayerAutochat(const std::optional<std::string>& requestId=std::nullopt)
            {
                bool cancelled=false;
                for(auto iterator=m_playerAutochats.begin();iterator!=m_playerAutochats.end();){
                    if(requestId&&iterator->first!=*requestId){++iterator;continue;}
                    if(iterator->second.request&&m_service)static_cast<void>(m_service->cancel(*iterator->second.request));
                    iterator=m_playerAutochats.erase(iterator);cancelled=true;
                    if(requestId)break;
                }
                return cancelled;
            }

            sol::object playerAutochatStatus(sol::state_view lua,const std::string& requestId) const
            {
                const auto found=m_playerAutochats.find(requestId);
                if(found==m_playerAutochats.end())return sol::make_object(lua,sol::nil);
                sol::table result(lua,sol::create);result["state"]=found->second.state;
                if(!found->second.text.empty())result["text"]=found->second.text;
                if(!found->second.reason.empty())result["reason"]=found->second.reason;
                return sol::make_object(lua,result);
            }

            sol::object mediaStatus(sol::state_view lua, const std::string& mediaId) const
            {
                const auto found = m_media.find(mediaId);
                if (found == m_media.end()) return sol::make_object(lua, sol::nil);
                  sol::table result(lua, sol::create); result["state"] = found->second.state;
                  if (!found->second.reason.empty()) result["reason"] = found->second.reason;
                  return sol::make_object(lua, result);
            }

            // Only bounded presentation values may cross this settings boundary.
            std::tuple<sol::object,sol::object> configurePlayback(sol::state_view lua,sol::table values,LuaManager* manager)
            {
                try{
                    static const std::vector<std::string> keys={"voice_volume_percent","head_voice_volume_percent","audio_mode","distance_scale","dropoff_inside_percent","dropoff_outside_percent","legacy_distance_scale","camera_based_audio","invert_heading","clip_start_ms","clip_end_ms","lip_intensity","lip_resolution_ms","pause_on_game_pause"};
                    for(const auto& entry:values){
                        if(!entry.first.is<std::string>()||std::find(keys.begin(),keys.end(),entry.first.as<std::string>())==keys.end())
                            return failure(lua,"unknown_playback_setting");
                    }
                    lorkhan::PlaybackSettings settings;
                    if(values["voice_volume_percent"].valid()){const auto value=values.get<sol::object>("voice_volume_percent");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        settings.voiceVolumePercent=static_cast<float>(number);}
                    if(values["head_voice_volume_percent"].valid()){const auto value=values.get<sol::object>("head_voice_volume_percent");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        settings.headVoiceVolumePercent=static_cast<float>(number);}
                    if(values["audio_mode"].valid()){const auto value=values.get<sol::object>("audio_mode");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        if(!std::isfinite(number)||number!=std::floor(number)||number<0||number>10000)return failure(lua,"invalid_playback_setting");
                        settings.audioMode=static_cast<int>(number);}
                    if(values["distance_scale"].valid()){const auto value=values.get<sol::object>("distance_scale");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        settings.distanceScale=static_cast<float>(number);}
                    if(values["dropoff_inside_percent"].valid()){const auto value=values.get<sol::object>("dropoff_inside_percent");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        settings.dropoffInsidePercent=static_cast<float>(number);}
                    if(values["dropoff_outside_percent"].valid()){const auto value=values.get<sol::object>("dropoff_outside_percent");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        settings.dropoffOutsidePercent=static_cast<float>(number);}
                    if(values["legacy_distance_scale"].valid()){const auto value=values.get<sol::object>("legacy_distance_scale");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        settings.legacyDistanceScale=static_cast<float>(number);}
                    if(values["camera_based_audio"].valid()){const auto value=values.get<sol::object>("camera_based_audio");
                        if(!value.is<bool>())return failure(lua,"invalid_playback_setting");settings.cameraBasedAudio=value.as<bool>();}
                    if(values["invert_heading"].valid()){const auto value=values.get<sol::object>("invert_heading");
                        if(!value.is<bool>())return failure(lua,"invalid_playback_setting");settings.invertHeading=value.as<bool>();}
                    if(values["clip_start_ms"].valid()){const auto value=values.get<sol::object>("clip_start_ms");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        if(!std::isfinite(number)||number!=std::floor(number)||number<0||number>10000)return failure(lua,"invalid_playback_setting");
                        settings.clipStartMs=static_cast<int>(number);}
                    if(values["clip_end_ms"].valid()){const auto value=values.get<sol::object>("clip_end_ms");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        if(!std::isfinite(number)||number!=std::floor(number)||number<0||number>10000)return failure(lua,"invalid_playback_setting");
                        settings.clipEndMs=static_cast<int>(number);}
                    if(values["lip_intensity"].valid()){const auto value=values.get<sol::object>("lip_intensity");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        settings.lipIntensity=static_cast<float>(number);}
                    if(values["lip_resolution_ms"].valid()){const auto value=values.get<sol::object>("lip_resolution_ms");
                        if(!value.is<double>())return failure(lua,"invalid_playback_setting");const double number=value.as<double>();
                        if(!std::isfinite(number)||number!=std::floor(number)||number<0||number>10000)return failure(lua,"invalid_playback_setting");
                        settings.lipResolutionMs=static_cast<int>(number);}
                    if(values["pause_on_game_pause"].valid()){const auto value=values.get<sol::object>("pause_on_game_pause");
                        if(!value.is<bool>())return failure(lua,"invalid_playback_setting");settings.pauseOnGamePause=value.as<bool>();}
                    if(!lorkhan::validPlayback(settings))return failure(lua,"invalid_playback_setting");
                    manager->addAction([settings]{MWBase::Environment::get().getSoundManager()->configureLorkhanPlayback(settings);});
                    return {sol::make_object(lua,true),sol::make_object(lua,sol::nil)};
                }catch(const std::exception& error){return failure(lua,error.what());}
            }

            std::tuple<sol::object,sol::object> configureTransport(sol::state_view lua,sol::table values)
            {
                try{
                    for(const auto& entry:values)if(!entry.first.is<std::string>()||entry.first.as<std::string>()!="connection_timeout_seconds")
                        return failure(lua,"unknown_transport_setting");
                    const auto value=values.get<sol::object>("connection_timeout_seconds");
                    if(!value.is<double>())return failure(lua,"invalid_connection_timeout");
                    const double seconds=value.as<double>();
                    if(!std::isfinite(seconds)||seconds!=std::floor(seconds)||seconds<15||seconds>300)return failure(lua,"invalid_connection_timeout");
                    if(!m_transport)return failure(lua,"bridge_not_configured");
                    m_transport->setConnectionTimeout(static_cast<int>(seconds));
                    return {sol::make_object(lua,true),sol::make_object(lua,sol::nil)};
                }catch(const std::exception& error){return failure(lua,error.what());}
            }

            std::tuple<sol::object, sol::object> playSpeech(sol::state_view lua, const std::string& mediaId,
                const sol::object& actor, const std::string& subtitle, float volumeBoost, LuaManager* luaManager)
            {
                try
                {
                    if (!std::isfinite(volumeBoost) || volumeBoost < 1.f || volumeBoost > 4.f)
                        return failure(lua, "invalid_tts_volume_boost");
                    const auto found = m_media.find(mediaId);
                    if (found == m_media.end() || found->second.state != "ready")
                        return failure(lua, "prepared_media_unavailable");
                    MWWorld::Ptr ptr = mutablePtrOrThrow(actor);
                    auto media = Files::openConstrainedFileStream(found->second.cachePath);
                    const std::string name = Files::pathToUnicodeString(found->second.cachePath.filename());
                    if (!MWBase::Environment::get().getSoundManager()->sayLorkhanMedia(
                            ptr, std::move(media), name, volumeBoost))
                        return failure(lua, "playback_failed");
                    if (luaManager && !subtitle.empty() && Settings::gui().mSubtitles)
                        luaManager->addUIMessage(subtitle);
                    return success(lua, mediaId);
                }
                catch (const std::exception& error)
                {
                    return failure(lua, error.what());
                }
            }

            std::tuple<sol::object, sol::object> showSubtitle(sol::state_view lua, const sol::object& actor,
                const std::string& subtitle, LuaManager* luaManager)
            {
                try
                {
                    static_cast<void>(mutablePtrOrThrow(actor));
                    if (subtitle.empty()) return failure(lua, "subtitle_empty");
                    if (luaManager && Settings::gui().mSubtitles) luaManager->addUIMessage(subtitle);
                    return success(lua, "shown");
                }
                catch (const std::exception& error) { return failure(lua, error.what()); }
            }

            bool isSpeechActive(const sol::object& actor) const
            {
                try
                {
                    return MWBase::Environment::get().getSoundManager()->sayActive(mutablePtrOrThrow(actor));
                }
                catch (...)
                {
                    return false;
                }
            }

            bool stopSpeech(const sol::object& actor) const
            {
                try
                {
                    MWBase::Environment::get().getSoundManager()->stopSay(mutablePtrOrThrow(actor));
                    return true;
                }
                catch (...)
                {
                    return false;
                }
            }

            bool releaseMedia(const std::string& mediaId)
            {
                return m_media.erase(mediaId) != 0;
            }

            std::tuple<sol::object, sol::object> submitActionResult(sol::state_view lua, sol::table dto)
            {
                if (!ready()) return failure(lua, "bridge_not_ready");
                try
                {
                    const std::string statusName = dto.get<std::string>("status");
                    const lorkhan::ActionTerminalStatus status = statusName == "succeeded" ? lorkhan::ActionTerminalStatus::succeeded
                        : statusName == "failed" ? lorkhan::ActionTerminalStatus::failed
                        : statusName == "rejected" ? lorkhan::ActionTerminalStatus::rejected
                        : statusName == "timed_out" ? lorkhan::ActionTerminalStatus::timed_out
                        : statusName == "cancelled" ? lorkhan::ActionTerminalStatus::cancelled
                        : throw std::runtime_error("invalid action terminal status");
                    const lorkhan::RequestId correlated(dto.get<std::string>("request_id"));
                    const lorkhan::RequestId transportRequest(uuid());
                    lorkhan::OutboundRequest request{ transportRequest, *m_session, m_service->generation(),
                        lorkhan::RequestKind::action_result,
                        lorkhan::ActionResultRequest{ lorkhan::MessageId(dto.get<std::string>("message_id")),
                            { correlated, *m_session, m_service->generation() },
                            lorkhan::ActionId(dto.get<std::string>("action_id")),
                            lorkhan::TurnId(dto.get<std::string>("turn_id")), status,
                            dto.get<std::string>("reason_code"), dto.get<sol::table>("observed").begin()==dto.get<sol::table>("observed").end()?"{}":toJson(dto.get<sol::object>("observed")),
                            dto.get<std::string>("completed_at") } };
                    auto retained=m_transfers.find(dto.get<std::string>("action_id"));
                    if(retained!=m_transfers.end()){
                        auto& transfer=retained->second;
                        if((statusName=="rejected"||statusName=="cancelled")&&transfer.gate.cancel())
                            transfer.status=statusName,transfer.reason=dto.get<std::string>("reason_code");
                        if(statusName!=transfer.status)return failure(lua,"transfer_terminal_mismatch");
                        if(transfer.receiptRequest&&(transfer.receiptStatus=="pending"||transfer.receiptStatus=="accepted"))
                            return success(lua,transfer.receiptRequest->value());
                        if(!transfer.receipt)transfer.receipt=std::get<lorkhan::ActionResultRequest>(request.payload);
                        request.payload=*transfer.receipt;
                    }
                    auto accepted = m_service->enqueue(std::move(request));
                    if (!accepted) return failure(lua, accepted.error().message);
                    if(retained!=m_transfers.end()){
                        retained->second.receiptRequest=transportRequest;retained->second.receiptStatus="pending";
                        retained->second.receiptReason.clear();
                    }
                    return success(lua, transportRequest.value());
                }
                catch (const std::exception& error) { return failure(lua, error.what()); }
            }

            std::tuple<sol::object, sol::object> submitDialogueDeliveryResult(sol::state_view lua, sol::table dto)
            {
                if (!ready()) return failure(lua, "bridge_not_ready");
                try
                {
                    const std::string statusName = dto.get<std::string>("status");
                    const lorkhan::DialogueDeliveryStatus status = statusName == "played" ? lorkhan::DialogueDeliveryStatus::played
                        : statusName == "failed" ? lorkhan::DialogueDeliveryStatus::failed
                        : statusName == "expired" ? lorkhan::DialogueDeliveryStatus::expired
                        : statusName == "interrupted" ? lorkhan::DialogueDeliveryStatus::interrupted
                        : throw std::runtime_error("invalid dialogue delivery status");
                    const lorkhan::RequestId correlated(dto.get<std::string>("request_id"));
                    const lorkhan::RequestId transportRequest(uuid());
                    lorkhan::OutboundRequest request{ transportRequest, *m_session, m_service->generation(),
                        lorkhan::RequestKind::dialogue_delivery_result,
                        lorkhan::DialogueDeliveryResultRequest{ lorkhan::MessageId(dto.get<std::string>("message_id")),
                            { correlated, *m_session, m_service->generation() },
                            lorkhan::MessageId(dto.get<std::string>("dialogue_message_id")),
                            lorkhan::TurnId(dto.get<std::string>("turn_id")),
                            toJson(dto.get<sol::object>("speaker")), status,
                            dto.get<std::string>("reason_code"), dto.get<std::string>("completed_at") } };
                    auto accepted = m_service->enqueue(std::move(request));
                    if (!accepted) return failure(lua, accepted.error().message);
                    return success(lua, transportRequest.value());
                }
                catch (const std::exception& error) { return failure(lua, error.what()); }
            }

            // One settlement path for every controls response. Success, a typed failure, a payload that
            // does not parse, and an unexpected response kind all clear the matching request and leave a
            // readable error behind, so a panel can never be stranded waiting on an answered request.
            bool settleControlsResult(const lorkhan::InboundResult& result)
            {
                if (!m_controlsRequest || result.request != *m_controlsRequest) return false;
                m_controlsRequest.reset();
                if (result.kind == lorkhan::ResponseKind::controls)
                {
                    auto parsed = lorkhan::parseControlsResponse(result.payload, jsonHeaders());
                    if (parsed) { m_controls = std::move(parsed).value(); m_controlsError.clear(); }
                    else m_controlsError = parsed.error().message;
                }
                else if (result.kind == lorkhan::ResponseKind::failure)
                    m_controlsError = result.failure ? result.failure->message : "transport_failure";
                else
                    m_controlsError = "unexpected_controls_response";
                return true;
            }

            // Settle debug queries in whichever native response lane drains them first.
            bool settleDebugResult(const lorkhan::InboundResult& result)
            {
                if (!m_debugRequest || result.request != *m_debugRequest) return false;
                m_debugRequest.reset();
                m_debugCommand.reset();
                if (result.kind == lorkhan::ResponseKind::debug_command)
                {
                    auto parsed = lorkhan::parseDebugCommandResponse(result.payload, jsonHeaders());
                    if (parsed) { m_debugCommand = std::move(parsed).value().command; m_debugError.clear(); }
                    else m_debugError = parsed.error().message;
                }
                else if (result.kind == lorkhan::ResponseKind::failure)
                    m_debugError = result.failure ? result.failure->message : "transport_failure";
                else
                    m_debugError = "unexpected_debug_response";
                return true;
            }

            // Settle the single player rewrite request without consuming unrelated global-lane results.
            bool settlePlayerAutochatResult(const lorkhan::InboundResult& result)
            {
                const auto found=m_playerAutochats.find(result.request.value());
                if(found==m_playerAutochats.end()||!found->second.request)return false;
                found->second.request.reset();
                if(result.kind==lorkhan::ResponseKind::player_autochat_ready){
                    auto parsed=lorkhan::parsePlayerAutochatReadyResponse(result.payload,jsonHeaders());
                    if(parsed){found->second.state="ready";found->second.text=parsed.value().text;found->second.reason.clear();}
                    else{found->second.state="failed";found->second.reason=parsed.error().message;}
                }else if(result.kind==lorkhan::ResponseKind::failure){
                    found->second.state="failed";
                    found->second.reason=result.failure?result.failure->message:"transport_failure";
                }else{found->second.state="failed";found->second.reason="unexpected_player_autochat_response";}
                return true;
            }

            // The Interact overlay owns Interface UI mode and pauses simulation, so the GLOBAL Lua lane
            // that drives poll stops running while a server-owned controls panel is open. Player onFrame
            // keeps running every frame, so this settles only the in-flight controls response. Every
            // other drained result is deferred, never consumed here, and replayed by poll, so the
            // authoritative lane still receives dialogue, speech, STT, action, failure, and event cursor
            // results exactly once and in arrival order.
            sol::table pumpSessionControls(sol::state_view lua)
            {
                sol::table status(lua, sol::create);
                bool settled = false;
                // Refusing to drain unless the bounded deferred queue can hold a whole batch keeps this
                // pump from ever having to discard a result it is not allowed to consume.
                if (m_service && m_controlsRequest
                    && m_deferredResults.size() + kControlsPumpBatch <= kDeferredResultCapacity)
                {
                    for (auto& result : m_service->poll(kControlsPumpBatch))
                    {
                        if (settleControlsResult(result)) { ++m_resultsSeen; settled = true; continue; }
                        m_deferredResults.push_back(std::move(result));
                    }
                }
                status["settled"] = settled;
                status["pending"] = m_controlsRequest.has_value();
                if (!m_controlsError.empty()) status["error"] = m_controlsError;
                return status;
            }

            // Drain only the current debug query while paused; every unrelated bridge result is replayed by poll().
            sol::table pumpDebugCommand(sol::state_view lua)
            {
                sol::table status(lua,sol::create);bool settled=false;
                if(m_service&&m_debugRequest&&m_deferredResults.size()+kControlsPumpBatch<=kDeferredResultCapacity){
                    for(auto& result:m_service->poll(kControlsPumpBatch)){
                        if(settleDebugResult(result)){++m_resultsSeen;settled=true;continue;}
                        m_deferredResults.push_back(std::move(result));
                    }
                }
                status["settled"]=settled;status["pending"]=m_debugRequest.has_value();
                if(!m_debugError.empty())status["error"]=m_debugError;
                if(m_debugCommand){sol::table command(lua,sol::create),parameters(lua,sol::create);
                    command["command_id"]=m_debugCommand->command.value();command["name"]=m_debugCommand->name;
                    command["expires_at"]=m_debugCommand->expiresAt;
                    for(const auto& [key,value]:m_debugCommand->parameters){
                        std::visit([&](const auto& parameter) {
                            if constexpr (std::is_same_v<std::decay_t<decltype(parameter)>, lorkhan::ProtocolIdentity>)
                                parameters[key] = identityTable(lua, parameter);
                            else parameters[key] = parameter;
                        }, value);
                    }
                    command["parameters"]=parameters;status["command"]=command;
                    m_debugCommand.reset();}
                return status;
            }

            sol::table pumpPlayerAutochat(sol::state_view lua)
            {
                sol::table status(lua,sol::create);bool settled=false;
                if(m_service&&!m_playerAutochats.empty()
                    &&m_deferredResults.size()+kControlsPumpBatch<=kDeferredResultCapacity){
                    for(auto& result:m_service->poll(kControlsPumpBatch)){
                        if(settlePlayerAutochatResult(result)){++m_resultsSeen;settled=true;continue;}
                        m_deferredResults.push_back(std::move(result));
                    }
                }
                status["settled"]=settled;status["pending"]=!m_playerAutochats.empty();
                return status;
            }

            sol::table poll(sol::state_view lua, std::size_t maximum)
            {
                sol::table output(lua, sol::create);
                if (!m_service) return output;
                std::size_t outIndex = 1;
                // Results the pause-safe pump had to drain are replayed ahead of newly drained ones so
                // the global lane keeps their arrival order and still processes each of them once.
                std::vector<lorkhan::InboundResult> results;
                results.swap(m_deferredResults);
                for (auto& drained : m_service->poll(std::min<std::size_t>(maximum, 128)))
                    results.push_back(std::move(drained));
                for (auto& result : results)
                {
                    if(settleTransferReceipt(result)){++m_resultsSeen;continue;}
                    ++m_resultsSeen;
                    if (settleDebugResult(result)) continue;
                    if (settleDiaryResult(result)) continue;
                    if (settlePlayerAutochatResult(result)) continue;
                    if (result.kind == lorkhan::ResponseKind::failure)
                    {
                        if(m_initRequest&&result.request==*m_initRequest){
                            m_initRequest.reset();
                            m_retryInit=result.failure&&(result.failure->retriable||result.failure->code==lorkhan::ErrorCode::transport_failure)&&m_initAttempts<3;
                            m_nextInit=std::chrono::steady_clock::now()+1000ms;
                            m_characterRejected=result.failure&&!result.failure->retriable
                                &&(result.failure->code==lorkhan::ErrorCode::duplicate_conflict
                                   ||result.failure->code==lorkhan::ErrorCode::action_disabled
                                   ||result.failure->code==lorkhan::ErrorCode::invalid_argument);
                        }

                        const auto failedTurn=m_turnRequests.find(result.request.value());
                        if(failedTurn!=m_turnRequests.end()){
                            sol::table failureEvent(lua,sol::create);
                            failureEvent["type"]="transport.failure";
                            failureEvent["request_id"]=result.request.value();
                            failureEvent["turn_id"]=failedTurn->second;
                            failureEvent["reason"]=result.failure?result.failure->message:"transport_failure";
                            output[outIndex++]=failureEvent;m_turnRequests.erase(failedTurn);
                        }
                        const bool pollFailure = m_pollRequest && result.request == *m_pollRequest;
                        bool menuFailure=false;
                        for(auto& [unused,dialogue]:m_menuDialogues){
                            static_cast<void>(unused);
                            if(dialogue.request&&result.request==*dialogue.request){dialogue.state="failed";
                                dialogue.reason=result.failure?result.failure->message:"transport_failure";
                                dialogue.request.reset();menuFailure=true;break;}}
                        bool mediaFailure = false;
                        for (auto& [mediaId, media] : m_media)
                        {
                            if (media.request && *media.request == result.request)
                            {
                                media.state = "failed";
                                media.reason = result.failure ? result.failure->message : "transport_failure";
                                media.request.reset();
                                for(auto& [unused,dialogue]:m_menuDialogues){
                                    static_cast<void>(unused);
                                    if(dialogue.media&&dialogue.media->media.value()==mediaId){
                                        dialogue.state="failed";dialogue.reason=media.reason;
                                        dialogue.request.reset();}}
                                mediaFailure = true;
                                break;
                            }
                        }
                        if (pollFailure)
                        {
                            m_pollRequest.reset();
                            const auto retry = result.failure && result.failure->retryAfterMs
                                ? std::chrono::milliseconds(*result.failure->retryAfterMs) : 1000ms;
                            m_nextPoll = std::chrono::steady_clock::now() + std::max(retry, 250ms);
                            if (m_session)
                                m_status = "ready";
                        }
                        settleControlsResult(result);
                        if (!m_session)
                            m_status = "error";
                        else if (!mediaFailure)
                            m_status = "ready";
                        if (!mediaFailure&&!menuFailure)
                            m_error = result.failure ? result.failure->message : "transport_failure";
                    }
                    else if (m_initRequest && result.request == *m_initRequest && result.kind == lorkhan::ResponseKind::accepted)
                    {
                        ++m_initMatches;
                        auto parsed = lorkhan::parseSessionAcceptedResponse(result.payload, jsonHeaders());
                        if (parsed)
                        {
                            if(parsed.value().characterId)m_characterIdentity.character=*parsed.value().characterId;
                            m_characterRejected=false;
                            m_loadedSave=false;m_loadedCalendar.reset();
                            m_session = parsed.value().session; m_cursor = parsed.value().eventCursor;
                            m_configRevision = parsed.value().configRevision;
                            m_clientSettings = parsed.value().clientSettings;
                            m_status = "ready"; m_error.clear(); m_initRequest.reset();
                        }
                        else
                        {
                            m_status = "error"; m_error = parsed.error().message; m_initRequest.reset();
                        }
                    }
                    else if (m_pollRequest && result.request == *m_pollRequest)
                    {
                        m_pollRequest.reset();
                        if (result.kind == lorkhan::ResponseKind::event)
                        {
                            auto parsed = lorkhan::parseEventsResponse(result.payload, jsonHeaders());
                            if (parsed)
                            {
                                m_cursor = parsed.value().nextAfter;
                                for (const auto& event : parsed.value().events) {
                                    retainTransfer(event);
                                    output[outIndex++] = eventTable(lua, event);
                                }
                            }
                        }
                    }
                    else if (result.kind == lorkhan::ResponseKind::media_ready)
                    {
                        const auto found = m_media.find(result.payload);
                        if (found != m_media.end())
                        {
                            found->second.state = "ready";
                            found->second.reason.clear();
                            found->second.request.reset();
                            for(auto& [unused,dialogue]:m_menuDialogues){
                                static_cast<void>(unused);
                                if(dialogue.media&&dialogue.media->media.value()==result.payload){
                                    dialogue.state="ready";dialogue.reason.clear();dialogue.request.reset();}}
                        }
                    }
                    else if(result.kind==lorkhan::ResponseKind::menu_dialogue_ready)
                    {
                        for(auto& [unused,dialogue]:m_menuDialogues){
                            static_cast<void>(unused);
                            if(!dialogue.request||result.request!=*dialogue.request)continue;
                            auto parsed=lorkhan::parseMenuDialogueTtsReadyResponse(result.payload,jsonHeaders());
                            if(!parsed){dialogue.state="failed";dialogue.reason=parsed.error().message;
                                dialogue.request.reset();}
                            else prepareMenuDialogueMedia(dialogue,parsed.value().media);
                            break;
                        }
                    }
                    else
                    {
                        settleControlsResult(result);
                    }
                    if(result.kind!=lorkhan::ResponseKind::failure)m_turnRequests.erase(result.request.value());
                }
                if(m_retryInit&&std::chrono::steady_clock::now()>=m_nextInit)beginSession();
                schedulePoll();
                return output;
            }

            // GLOBAL save lifecycle selects a stable character before any network session can begin.
            std::tuple<sol::object,sol::object> configureCharacter(sol::state_view lua,sol::table values)
            {
                try {
                    if(!m_config||!m_service)return failure(lua,"bridge_not_configured");
                    static const std::set<std::string> keys={"mode","character_id","playthrough_id","character_binding","generation"};
                    for(const auto& entry:values)if(!entry.first.is<std::string>()||!keys.contains(entry.first.as<std::string>()))
                        return failure(lua,"invalid_character_identity_field");
                    const auto text=[&](const char* key){const sol::object value=values[key];
                        if(value==sol::nil)return std::string{};
                        if(!value.is<std::string>())throw std::invalid_argument("invalid_character_identity_field");
                        return value.as<std::string>();};
                    const auto mode=text("mode");
                    if(mode=="new_game"||mode=="load"){
                        m_characterIdentity.prepare(mode=="new_game",text("character_id"),text("playthrough_id"),
                            text("character_binding"),m_legacyPlaythrough,[]{return uuid();});
                    }else if(mode=="existing"||mode=="new"){
                        const sol::object supplied=values["generation"];
                        if(!supplied.is<double>()||supplied.as<double>()!=static_cast<double>(generation()))
                            return failure(lua,"stale_character_selection");
                        if(m_characterRejected){
                            if(text("character_id")!=m_characterIdentity.character)return failure(lua,"stale_character_selection");
                            m_characterIdentity.playthrough.clear();m_characterIdentity.binding.clear();
                            m_initSnapshot.reset();m_initAttempts=0;m_retryInit=false;m_characterRejected=false;
                        }
                        m_characterIdentity.choose(text("character_id"),mode,[]{return uuid();});
                    }else return failure(lua,"invalid_character_identity_mode");
                    if(m_characterIdentity.selected()){
                        m_config->playthrough=lorkhan::PlaythroughId(m_characterIdentity.playthrough);
                        if(!m_session){beginSession();m_status="connecting";}
                    }else m_status="waiting_identity";
                    return {sol::make_object(lua,characterInfo(lua)),sol::make_object(lua,sol::nil)};
                }catch(const std::exception& error){return failure(lua,error.what());}
            }

            // Expose confirmed identity separately from the provisional handshake choice.
            sol::table characterInfo(sol::state_view lua) const
            {
                sol::table result(lua,sol::create);
                result["character_id"]=m_characterIdentity.character;result["legacy_playthrough_id"]=m_characterIdentity.legacyPlaythrough;
                result["generation"]=generation();result["ready"]=m_session.has_value();
                result["needs_choice"]=m_characterRejected||!m_characterIdentity.selected();
                if(m_characterRejected)result["error"]=m_error;
                if(m_characterIdentity.selected()){
                    result["playthrough_id"]=m_characterIdentity.playthrough;result["character_binding"]=m_characterIdentity.binding;
                }
                return result;
            }

            bool cancelGeneration(std::uint64_t generation, bool loadedSave = false, bool identityChange = false)
            {
                if (!m_service) return false;
                auto result = m_service->cancelGeneration(lorkhan::Generation(generation));
                if (!result) return false;
                cancelMenuDialogueTts();
                cancelPlayerAutochat();
                m_session.reset(); m_clientSettings.reset(); m_configRevision.clear();
                m_pollRequest.reset(); m_initRequest.reset();m_controlsRequest.reset();m_controls.reset();
                m_diaryRequest.reset();m_diaryReceipt.reset();m_diaryBook.reset();m_diaryReceiptDto.reset();m_diaryPending=false;
                m_diaryState.clear();m_diaryReason.clear();m_diaryError.clear();m_diaryReceiptOk=false;
                m_debugRequest.reset();m_debugCommand.reset();m_deferredResults.clear();m_turnRequests.clear();m_controlsError.clear();m_debugError.clear();
                m_initSnapshot.reset();m_initAttempts=0;m_retryInit=false;
                if(identityChange){m_characterIdentity.clear();m_characterRejected=false;}
                m_loadedSave=loadedSave;m_waitingLoadedCalendar=loadedSave;m_loadedCalendar.reset();beginSession();
                m_status = m_characterIdentity.selected()?"connecting":"waiting_identity";
                return true;
            }

            // Finish only a real load fence, after GLOBAL Lua can read the loaded player's calendar.
            bool finishLoadedSave(sol::optional<sol::table> value)
            {
                if(!m_waitingLoadedCalendar)return false;
                if(value){
                    const auto year=(*value)["year"].get_or<double>(0),month=(*value)["month"].get_or<double>(-1);
                    const auto day=(*value)["day"].get_or<double>(0),hour=(*value)["hour"].get_or<double>(-1);
                    if(!std::isfinite(year)||!std::isfinite(month)||!std::isfinite(day)
                        ||year<1||year>9999||month<0||month>11||day<1||day>31
                        ||std::floor(year)!=year||std::floor(month)!=month||std::floor(day)!=day)return false;
                    lorkhan::LoadedSaveCalendar calendar{static_cast<int>(year),static_cast<int>(month),static_cast<int>(day),hour};
                    if(!calendar.valid())return false;
                    m_loadedCalendar=calendar;
                }
                m_waitingLoadedCalendar=false;beginSession();return true;
            }

            void halt()
            {
                lorkhan::VoiceCaptureService::instance().halt();
                if (m_service) m_service->halt();
                m_turnRequests.clear();
                m_status = "halted";
            }

        private:
            static lorkhan::Headers jsonHeaders()
            {
                return { { "Content-Type", "application/json; charset=utf-8" } };
            }
            static std::tuple<sol::object, sol::object> failure(sol::state_view lua, const std::string& reason)
            { return { sol::make_object(lua, sol::nil), sol::make_object(lua, reason) }; }
            static std::tuple<sol::object, sol::object> success(sol::state_view lua, const std::string& value)
            { return { sol::make_object(lua, value), sol::make_object(lua, sol::nil) }; }

            // Queue the authenticated media download after a menu TTS response has passed strict parsing.
            void prepareMenuDialogueMedia(MenuDialogueState& dialogue,const lorkhan::CanonicalMediaDescriptor& media)
            {
                try{
                    dialogue.media=media;dialogue.request.reset();
                    const auto existing=m_media.find(media.media.value());
                    if(existing!=m_media.end()){
                        dialogue.state=existing->second.state;dialogue.reason=existing->second.reason;
                        return;
                    }
                    lorkhan::MediaDescriptor descriptor{media.media,parseSha256(media.sha256),
                        static_cast<std::size_t>(media.bytes),media.codec,parseUtc(media.expiresAt)};
                    const lorkhan::RequestId request(uuid());
                    lorkhan::OutboundRequest outbound{request,*m_session,m_service->generation(),lorkhan::RequestKind::media,
                        lorkhan::MediaPrepareRequest{{request,*m_session,m_service->generation()},descriptor}};
                    auto accepted=m_service->enqueue(std::move(outbound));
                    if(!accepted)throw std::runtime_error(accepted.error().message);
                    const std::string extension=media.codec==lorkhan::MediaCodec::wav?".wav"
                        :media.codec==lorkhan::MediaCodec::ogg?".ogg":".mp3";
                    m_media[media.media.value()]={"preparing",
                        m_config->cacheRoot/media.sha256.substr(0,2)/(media.sha256+extension),{},request};
                    dialogue.state="preparing";dialogue.reason.clear();
                }catch(const std::exception& error){dialogue.state="failed";
                    dialogue.reason=error.what();dialogue.request.reset();}
            }

            void beginSession()
            {
                if (!m_service || !m_config || !m_characterIdentity.selected() || m_initRequest || m_waitingLoadedCalendar) return;
                const lorkhan::RequestId request(uuid());
                if(!m_initSnapshot){
                    lorkhan::EnvelopeIds ids{m_config->installation,m_config->profile,m_config->playthrough,{},request,
                        lorkhan::TurnId(uuid()),lorkhan::MessageId(uuid()),m_service->generation()};
                    lorkhan::RuntimeInfo runtime;runtime.platform=m_config->platform;runtime.capabilities=capabilities();
                    m_initSnapshot=lorkhan::InitRequest{std::move(ids),std::move(runtime),m_config->fingerprint,utcNow()};
                    m_initSnapshot->loadedSave=m_loadedSave;m_initSnapshot->loadedCalendar=m_loadedCalendar;
                    m_initSnapshot->characterId=m_characterIdentity.character;m_initSnapshot->characterBinding=m_characterIdentity.binding;
                }
                // Retries use a fresh local request token but exactly the same HTTP body and idempotency key.
                auto init=*m_initSnapshot;init.ids.request=request;
                lorkhan::OutboundRequest outbound{request,{},init.ids.generation,lorkhan::RequestKind::init,std::move(init)};
                m_retryInit=false;++m_initAttempts;
                auto result = m_service->enqueue(std::move(outbound));
                if (result) m_initRequest = request;
                else { m_status = "error"; m_error = result.error().message; }
            }

            void schedulePoll()
            {
                if (!ready() || m_pollRequest) return;
                const auto now = std::chrono::steady_clock::now();
                if (now < m_nextPoll) return;
                const lorkhan::RequestId request(uuid());
                lorkhan::OutboundRequest outbound{ request, *m_session, m_service->generation(),
                    lorkhan::RequestKind::event_poll,
                    lorkhan::EventPollRequest{ *m_session, m_service->generation(), m_cursor, 1000 } };
                auto result = m_service->enqueue(std::move(outbound));
                if (result) m_pollRequest = request;
                m_nextPoll = now + 250ms;
            }

            static std::vector<std::string> capabilities()
            { return { "diary.books.v1", "context.item_pickup.v1", "context.spell_cast.v1", "context.actor_resurrected.v1", "dialogue.text", "speech.say", "speech.listen", "controls.session", "debug.commands.v1", "debug.npc_manager.v1", "speech.browser.v1", "action.item.create", "action.gold.create", "action.actor.spawn", "action.actor.teleport_to_player", "action.player.teleport", "action.actor.restore", "action.actor.resurrect", "action.actor.kill", "action.conversation.end", "action.ai.follow", "action.ai.stop",
                "action.ai.approach", "action.ai.wait", "action.ai.travel", "action.ai.escort", "action.ai.face", "action.ai.wander", "action.combat.start",
                "action.combat.stop", "action.weapon.sheathe", "action.item.give", "action.item.take", "action.item.pickup", "action.gold.give", "action.gold.take", "action.service.barter", "action.service.training", "action.service.spells", "action.service.travel", "action.service.spellmaking", "action.service.enchanting", "action.service.repair", "action.spell.cast", "action.animation.play", "action.item.equip", "action.item.unequip", "action.item.use",
                "action.inspect.report", "action.inventory.inspect", "action.confirmation", "action.result-followup" }; }

            static sol::table eventTable(sol::state_view lua, const lorkhan::ProtocolEvent& event)
            {
                sol::table result(lua, sol::create), payload(lua, sol::create);
                result["message_id"] = event.correlation.message.value(); result["request_id"] = event.correlation.request.value();
                result["turn_id"] = event.correlation.turn.value(); result["session_id"] = event.correlation.session.value();
                result["generation"] = event.correlation.generation.value(); result["sequence"] = event.sequence;
                result["created_at"] = event.createdAt;
                switch (event.type)
                {
                    case lorkhan::ProtocolEventType::turn_accepted: result["type"] = "turn.accepted"; break;
                    case lorkhan::ProtocolEventType::dialogue_delta: {
                        result["type"] = "dialogue.delta";
                        const auto& item = std::get<lorkhan::DialogueDeltaEventPayload>(event.payload);
                        payload["text"] = item.text; break; }
                    case lorkhan::ProtocolEventType::dialogue_complete: {
                        result["type"] = "dialogue.complete";
                        const auto& item = std::get<lorkhan::DialogueCompleteEventPayload>(event.payload);
                        payload["speaker"] = identityTable(lua, item.speaker); payload["addressee"] = identityTable(lua, item.addressee);
                        payload["text"] = item.text; break; }
                    case lorkhan::ProtocolEventType::action_intent: {
                        result["type"] = "action.intent";
                        const auto& item = std::get<lorkhan::ActionIntentEventPayload>(event.payload).intent;
                        payload["schema"] = "lorkhan.action-intent.v1"; payload["action_id"] = item.action.value();
                        payload["request_id"] = event.correlation.request.value(); payload["turn_id"] = item.turn.value();
                        payload["session_id"] = event.correlation.session.value(); payload["generation"] = event.correlation.generation.value();
                        const char* name = "inspect.report";
                        int tier = 0;
                        switch (item.kind) {
                            case lorkhan::ActionIntentKind::ai_follow: name = "ai.follow"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_stop: name = "ai.stop"; tier = 1; break;
                            case lorkhan::ActionIntentKind::conversation_end: name = "conversation.end"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_approach: name = "ai.approach"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_wait: name = "ai.wait"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_travel: name = "ai.travel"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_escort: name = "ai.escort"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_face: name = "ai.face"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_wander: name = "ai.wander"; tier = 1; break;
                            case lorkhan::ActionIntentKind::animation_play: name = "animation.play"; tier = 1; break;
                            case lorkhan::ActionIntentKind::combat_start: name = "combat.start"; tier = 2; break;
                            case lorkhan::ActionIntentKind::combat_stop: name = "combat.stop"; tier = 1; break;
                            case lorkhan::ActionIntentKind::weapon_sheathe: name = "weapon.sheathe"; tier = 1; break;
                            case lorkhan::ActionIntentKind::inspect_report: break;
                            case lorkhan::ActionIntentKind::inventory_inspect: name = "inventory.inspect"; break;
                            case lorkhan::ActionIntentKind::item_equip: name = "item.equip"; tier = 2; break;
                            case lorkhan::ActionIntentKind::item_unequip: name = "item.unequip"; tier = 2; break;
                            case lorkhan::ActionIntentKind::item_use: name = "item.use"; tier = 2; break;
                            case lorkhan::ActionIntentKind::item_give: name = "item.give"; tier = 2; break;
                            case lorkhan::ActionIntentKind::item_take: name = "item.take"; tier = 2; break;
                            case lorkhan::ActionIntentKind::item_pickup: name = "item.pickup"; tier = 2; break;
                            case lorkhan::ActionIntentKind::gold_give: name = "gold.give"; tier = 2; break;
                            case lorkhan::ActionIntentKind::gold_take: name = "gold.take"; tier = 2; break;
                            case lorkhan::ActionIntentKind::service_barter: name = "service.barter"; tier = 1; break;
                            case lorkhan::ActionIntentKind::service_training: name = "service.training"; tier = 1; break;
                            case lorkhan::ActionIntentKind::service_spells: name = "service.spells"; tier = 1; break;
                            case lorkhan::ActionIntentKind::service_travel: name = "service.travel"; tier = 1; break;
                            case lorkhan::ActionIntentKind::service_spellmaking: name = "service.spellmaking"; tier = 1; break;
                            case lorkhan::ActionIntentKind::service_enchanting: name = "service.enchanting"; tier = 1; break;
                            case lorkhan::ActionIntentKind::spell_cast: name = "spell.cast"; tier = 2; break;
                            case lorkhan::ActionIntentKind::item_create: name = "item.create"; tier = 2; break;
                            case lorkhan::ActionIntentKind::gold_create: name = "gold.create"; tier = 2; break;
                            case lorkhan::ActionIntentKind::actor_spawn: name = "actor.spawn"; tier = 2; break;
                            case lorkhan::ActionIntentKind::actor_teleport_to_player: name = "actor.teleport_to_player"; tier = 2; break;
                            case lorkhan::ActionIntentKind::player_teleport: name = "player.teleport"; tier = 2; break;
                            case lorkhan::ActionIntentKind::actor_restore: name = "actor.restore"; tier = 2; break;
                            case lorkhan::ActionIntentKind::actor_resurrect: name = "actor.resurrect"; tier = 2; break;
                            case lorkhan::ActionIntentKind::actor_kill: name = "actor.kill"; tier = 2; break;
                            case lorkhan::ActionIntentKind::service_repair: name = "service.repair"; tier = 1; break;

                        }
                        payload["name"] = name; payload["tier"] = tier;
                        payload["actor"] = identityTable(lua, item.actor); payload["target"] = identityTable(lua, item.target);
                        sol::table parameters(lua, sol::create);
                        if (item.kind == lorkhan::ActionIntentKind::ai_follow) parameters["distance"] = item.followDistance;
                        if (item.kind == lorkhan::ActionIntentKind::ai_wander) {
                            parameters["distance"] = item.wanderDistance;
                            parameters["duration_seconds"] = item.wanderDurationSeconds;
                        }
                        if (item.kind == lorkhan::ActionIntentKind::ai_wait)
                            parameters["duration_seconds"] = item.wanderDurationSeconds;
                        if(item.kind==lorkhan::ActionIntentKind::ai_travel||item.kind==lorkhan::ActionIntentKind::ai_escort){
                            parameters["destination_x"]=item.destinationX;parameters["destination_y"]=item.destinationY;
                            parameters["destination_z"]=item.destinationZ;parameters["destination_cell"]=item.destinationCell;
                        }
                        if (item.kind == lorkhan::ActionIntentKind::animation_play) parameters["group"] = item.stringParameter;
                        if (item.kind == lorkhan::ActionIntentKind::item_equip) {
                            parameters["record_id"] = item.stringParameter;
                            parameters["slot"] = item.secondaryStringParameter;
                        }
                        if (item.kind == lorkhan::ActionIntentKind::item_unequip)
                            parameters["slot"] = item.secondaryStringParameter;
                        if (item.kind == lorkhan::ActionIntentKind::item_use) parameters["record_id"] = item.stringParameter;
                        if(item.kind==lorkhan::ActionIntentKind::item_give||item.kind==lorkhan::ActionIntentKind::item_take
                            ||item.kind==lorkhan::ActionIntentKind::item_pickup)parameters["item_id"]=item.stringParameter;
                        if(item.kind==lorkhan::ActionIntentKind::item_give||item.kind==lorkhan::ActionIntentKind::item_take)
                            parameters["count"]=item.transferCount;
                        if(item.kind==lorkhan::ActionIntentKind::spell_cast)parameters["spell_id"]=item.stringParameter;
                        if(item.kind==lorkhan::ActionIntentKind::item_create||item.kind==lorkhan::ActionIntentKind::actor_spawn){parameters["record_id"]=item.stringParameter;parameters["count"]=item.transferCount;}
                        if(item.kind==lorkhan::ActionIntentKind::gold_create)parameters["amount"]=item.transferCount;
                        if(item.kind==lorkhan::ActionIntentKind::player_teleport)parameters["destination_id"]=item.stringParameter;
                        if(item.kind==lorkhan::ActionIntentKind::gold_give||item.kind==lorkhan::ActionIntentKind::gold_take)
                            parameters["amount"]=item.transferCount;
                        payload["parameters"] = parameters;
                        if (!item.displayName.empty()) payload["display_name"] = item.displayName;
                        if (item.confirmationRequired) payload["confirmation_required"] = *item.confirmationRequired;
                        if (item.followupEnabled) payload["followup_enabled"] = *item.followupEnabled;
                        if (item.followupActionsAllowed) payload["followup_actions_allowed"] = *item.followupActionsAllowed;
                        if (item.followupDepth) payload["followup_depth"] = *item.followupDepth;
                        payload["expires_at"] = item.expiresAt; break; }
                    case lorkhan::ProtocolEventType::director_instructions: {
                        result["type"]="director.instructions";
                        const auto& item=std::get<lorkhan::DirectorInstructionsEventPayload>(event.payload);
                        payload["plan_id"]=item.plan.value();payload["origin_turn_id"]=item.originTurn.value();
                        payload["expires_at"]=item.expiresAt;sol::table instructions(lua,sol::create);
                        for(std::size_t index=0;index<item.instructions.size();++index){
                            const auto& instruction=item.instructions[index];sol::table row(lua,sol::create);
                            row["instruction_id"]=instruction.instruction.value();row["actor"]=identityTable(lua,instruction.actor);
                            row["recipient"]=identityTable(lua,instruction.recipient);row["instruction"]=instruction.text;
                            row["scene_note"]=instruction.sceneNote;instructions[index+1]=row;
                        }
                        payload["instructions"]=instructions;break;
                    }
                    case lorkhan::ProtocolEventType::response_complete: {
                        result["type"] = "response.complete";
                        const auto& item = std::get<lorkhan::ResponseCompleteEventPayload>(event.payload);
                        payload = canonicalResponseTable(lua, item.response); break; }
                    case lorkhan::ProtocolEventType::turn_complete: result["type"] = "turn.complete"; break;
                    case lorkhan::ProtocolEventType::turn_cancelled:
                        result["type"] = "turn.cancelled";
                        payload["reason"] = std::get<lorkhan::TurnCancelledEventPayload>(event.payload).reason; break;
                    case lorkhan::ProtocolEventType::turn_failed: {
                        result["type"] = "turn.failed";
                        const auto& item = std::get<lorkhan::TurnFailedEventPayload>(event.payload);
                        payload["code"] = static_cast<int>(item.code); payload["retriable"] = item.retriable;
                        if (item.retryAfterMs)
                            payload["retry_after_ms"] = *item.retryAfterMs;
                        break; }
                    case lorkhan::ProtocolEventType::stt_transcript: {
                        result["type"] = "stt.transcript"; const auto& item = std::get<lorkhan::SttTranscriptEventPayload>(event.payload);
                        payload["text"] = item.text; payload["language"] = item.language; break; }
                    case lorkhan::ProtocolEventType::stt_failed: {
                        result["type"] = "stt.failed"; const auto& item = std::get<lorkhan::SttFailedEventPayload>(event.payload);
                        payload["code"] = item.code; payload["retriable"] = item.retriable;
                        if (item.retryAfterMs)
                            payload["retry_after_ms"] = *item.retryAfterMs;
                        break; }
                    case lorkhan::ProtocolEventType::speech_ready: {
                        result["type"] = "speech.ready"; const auto& item = std::get<lorkhan::SpeechReadyEventPayload>(event.payload);
                        payload["media_id"] = item.media.value(); payload["dialogue_message_id"] = item.dialogueMessage.value();
                        payload["sha256"] = item.sha256; payload["bytes"] = item.bytes;
                        payload["codec"] = item.codec == lorkhan::MediaCodec::wav ? "wav" : item.codec == lorkhan::MediaCodec::ogg ? "ogg" : "mp3";
                        payload["duration_ms"] = item.durationMs; payload["expires_at"] = item.expiresAt; break; }
                }
                result["payload"] = payload;
                return result;
            }

            std::optional<ClientConfig> m_config;
            lorkhan::BeastTransport* m_transport=nullptr;
            bool m_characterRejected=false;
            lorkhan::CharacterSessionIdentity m_characterIdentity;
            std::string m_legacyPlaythrough;
            std::unique_ptr<lorkhan::BridgeService> m_service;
            std::optional<lorkhan::SessionId> m_session;
            std::optional<lorkhan::ClientSettings> m_clientSettings;
            std::string m_configRevision;
            std::optional<lorkhan::RequestId> m_initRequest;
            std::optional<lorkhan::InitRequest> m_initSnapshot;
            unsigned m_initAttempts=0;
            bool m_retryInit=false;
            std::chrono::steady_clock::time_point m_nextInit;
            bool m_waitingLoadedCalendar=false;
            bool m_loadedSave=false;
            std::optional<lorkhan::LoadedSaveCalendar> m_loadedCalendar;
            std::optional<lorkhan::RequestId> m_pollRequest;
            std::optional<lorkhan::RequestId> m_controlsRequest;
            std::optional<lorkhan::ControlsResponse> m_controls;
            std::string m_controlsError;
            std::optional<lorkhan::RequestId> m_diaryRequest,m_diaryReceipt;
            std::optional<lorkhan::DiaryBookResponse::Book> m_diaryBook;
            std::optional<lorkhan::DiaryBookResultRequest> m_diaryReceiptDto;
            std::uint64_t m_diarySerial{};
            bool m_diaryPending{},m_diaryReceiptOk{};
            std::string m_diaryState,m_diaryReason,m_diaryError;
            std::optional<lorkhan::RequestId> m_debugRequest;
            std::optional<lorkhan::DebugCommandResponse::Command> m_debugCommand;
            std::string m_debugError;
            static constexpr std::size_t kControlsPumpBatch = 8;
            static constexpr std::size_t kDeferredResultCapacity = lorkhan::kInboundCapacity;
            std::vector<lorkhan::InboundResult> m_deferredResults;
            std::map<std::string,std::string> m_turnRequests;
            std::string m_transferSession;
            std::uint64_t m_transferGeneration{};
            std::map<std::string,std::shared_ptr<TransferSnapshot>> m_transferSnapshots;
            std::deque<std::string> m_transferOrder;
            std::map<std::string,TransferRecord> m_transfers;
            std::uint64_t m_cursor{};
            std::chrono::steady_clock::time_point m_nextPoll{};
            std::map<std::string, MediaState> m_media;
            std::map<std::string, MenuDialogueState> m_menuDialogues;
            std::map<std::string, PlayerAutochatState> m_playerAutochats;
            std::string m_status{"unconfigured"};
            std::string m_error;
            std::uint64_t m_resultsSeen{};
            std::uint64_t m_initMatches{};
        };

        NativeClient* activeClient = nullptr;

        NativeClient& client()
        {
            static NativeClient instance;
            activeClient = &instance;
            return instance;
        }

        sol::object makePackage(sol::state_view lua, LuaManager* luaManager, bool global)
        {
            sol::table api(lua, sol::create);
            api["version"] = std::string(lorkhan::kClientVersion);
            api["capabilities"] = [lua] {
                sol::table result(lua, sol::create); std::size_t index = 1;
            for (const auto& capability : std::vector<std::string>{ "diary.books.v1", "context.item_pickup.v1", "context.spell_cast.v1", "context.actor_resurrected.v1", "dialogue.text", "speech.say", "speech.listen", "controls.session",
                "action.item.create", "action.gold.create", "action.actor.spawn", "action.actor.teleport_to_player", "action.player.teleport", "action.actor.restore", "action.actor.resurrect", "action.actor.kill",
                "action.ai.follow", "action.ai.stop", "action.ai.approach", "action.ai.wait", "action.ai.travel", "action.ai.escort", "action.ai.face", "action.ai.wander",
                "action.combat.start", "action.combat.stop", "action.weapon.sheathe", "action.item.give", "action.item.take", "action.item.pickup", "action.gold.give", "action.gold.take", "action.service.barter", "action.service.training", "action.service.spells", "action.service.travel", "action.service.spellmaking", "action.service.enchanting", "action.service.repair", "action.spell.cast", "action.animation.play", "action.item.equip", "action.item.unequip",
                "action.item.use", "action.inspect.report", "action.inventory.inspect", "action.confirmation", "action.result-followup" })
                    result[index++] = capability;
                return result;
            };
            api["status"] = [] { return client().status(); };
            api["lastError"] = [] { return client().error(); };
            api["serverBaseUrl"] = [] { return client().serverBaseUrl(); };
            api["generation"] = [] { return client().generation(); };
            api["diagnostics"] = [lua] { return client().diagnostics(lua); };
            api["isExpired"] = [](const std::string& timestamp) {
                try { return parseUtc(timestamp) <= std::chrono::system_clock::now(); }
                catch (...) { return true; }
            };
            api["utcNow"] = [] { return utcNow(); };
            api["newMessageId"] = [] { return uuid(); };
            api["sessionInfo"] = [lua] { return client().sessionInfo(lua); };
            api["nextTurnMetadata"] = [lua] { return client().nextTurnMetadata(lua); };
            api["submitTurn"] = [lua](sol::table dto) { return client().submitTurn(lua, std::move(dto)); };
            api["submitCapturedDialogue"] = [lua](sol::table payload) {
                return client().submitCapturedDialogue(lua, std::move(payload));
            };
            api["submitItemPickup"] = [lua](sol::table payload) {
                return client().submitGameData(lua, lorkhan::GameDataType::item_pickup, std::move(payload));
            };
            api["submitActorResurrected"] = [lua](sol::table payload) {
                return client().submitGameData(lua, lorkhan::GameDataType::actor_resurrected, std::move(payload));
            };
            api["submitSpellCast"] = [lua](sol::table payload) {
                return client().submitGameData(lua, lorkhan::GameDataType::spell_cast, std::move(payload));
            };
            api["submitInventory"] = [lua](sol::table payload) {
                return client().submitInventory(lua, std::move(payload));
            };
            api["submitActorProfile"] = [lua](sol::table payload) {
                return client().submitActorProfile(lua, std::move(payload));
            };
            api["submitAutomaticDiary"] = [lua](sol::table payload) {
                return client().submitAutomaticDiary(lua, std::move(payload));
            };
            api["requestSessionControls"] = [lua](sol::table target) { return client().requestControls(lua,std::move(target)); };
            api["selectSessionControl"] = [lua](const std::string& kind,sol::optional<std::string> selection,sol::table target) {
                return client().selectControl(lua,kind,std::move(selection),std::move(target));
            };
            api["sessionControls"] = [lua] { return client().sessionControls(lua); };
            api["pumpSessionControls"] = [lua] { return client().pumpSessionControls(lua); };
            api["pumpPlayerAutochat"] = [lua] { return client().pumpPlayerAutochat(lua); };
            if(global){
                api["characterInfo"]=[lua]{return client().characterInfo(lua);};
                api["configureCharacter"]=[lua](sol::table values){return client().configureCharacter(lua,values);};
                api["configurePlayback"]=[lua,luaManager](sol::table values){return client().configurePlayback(lua,values,luaManager);};
                api["configureTransport"]=[lua](sol::table values){return client().configureTransport(lua,values);};
                api["executeAdvanced"]=[lua,luaManager](const std::string& id){return client().executeTransfer(lua,luaManager,id);};
                api["cancelAdvanced"]=[](const std::string& id){client().cancelTransfer(id);};
                api["advancedReceiptStatus"]=[lua](const std::string& id){return client().transferReceiptStatus(lua,id);};
                api["advancedActionSummary"]=[](const std::string& id){return client().advancedActionSummary(id);};
                api["executeTransfer"]=[lua,luaManager](const std::string& id){return client().executeTransfer(lua,luaManager,id);};
                api["cancelTransfer"]=[](const std::string& id){client().cancelTransfer(id);};
                api["transferReceiptStatus"]=[lua](const std::string& id){return client().transferReceiptStatus(lua,id);};
                api["executeSpell"]=[lua,luaManager](const std::string& id){return client().executeTransfer(lua,luaManager,id);};
                api["cancelSpell"]=[](const std::string& id){client().cancelTransfer(id);};
                api["spellReceiptStatus"]=[lua](const std::string& id){return client().transferReceiptStatus(lua,id);};
                api["executeService"]=[lua,luaManager](const std::string& id){return client().executeTransfer(lua,luaManager,id);};
                api["cancelService"]=[](const std::string& id){client().cancelTransfer(id);};
                api["serviceReceiptStatus"]=[lua](const std::string& id){return client().transferReceiptStatus(lua,id);};
                api["actorSpells"]=[lua](const GObject& actor){return NativeClient::actorSpells(lua,actor.ptr());};
                api["actorServices"]=[lua](const GObject& actor){return NativeClient::actorServices(lua,actor.ptr());};
                api["actorRecordProvenance"] = [lua](const GObject& actor) {
                    return recordProvenanceTable(lua, actor.ptr());
                };
                api["cancelDiaryBook"]=[]{client().cancelDiaryBook();};
                api["requestDiaryBook"]=[lua]{return client().requestDiaryBook(lua);};
                api["pumpDiaryBook"]=[lua]{return client().pumpDiaryBook(lua);};
                api["pumpDiaryBookResult"]=[lua]{return client().pumpDiaryBook(lua,true);};
                api["materializeDiaryBook"]=[lua,luaManager](const GObject& actor,const std::string& delivery){
                    return client().materializeDiaryBook(lua,luaManager,actor,delivery);};
                api["diaryBookStatus"]=[lua](const std::string& delivery){return client().diaryBookStatus(lua,delivery);};
                api["submitDiaryBookResult"]=[lua](const std::string& delivery,const std::string& status,sol::optional<std::string> reason){
                    return client().submitDiaryBookResult(lua,delivery,status,reason);};
            }
            api["requestDebugCommand"] = [lua] { return client().requestDebugCommand(lua); };
            api["pumpDebugCommand"] = [lua] { return client().pumpDebugCommand(lua); };
            api["submitDebugCommandResult"] = [lua](const std::string& commandId,const std::string& status,
                const std::string& reason,sol::table observed) {
                return client().submitDebugCommandResult(lua,commandId,status,reason,std::move(observed)); };
            api["voiceCaptureSupported"] = [] { return lorkhan::VoiceCaptureService::instance().supported(); };
            api["startVoiceCapture"] = [lua](sol::optional<bool> automatic,sol::optional<int> threshold,
                sol::optional<int> delay,sol::optional<int> deviceId) {
                return client().startVoiceCapture(lua,automatic.value_or(false),threshold.value_or(700),
                    delay.value_or(900),deviceId.value_or(-1)); };
            api["stopVoiceCapture"] = [] { client().stopVoiceCapture(); };
            api["cancelVoiceCapture"] = [] { client().cancelVoiceCapture(); };
            api["voiceCaptureStatus"] = [lua] { return client().voiceCaptureStatus(lua); };
            api["currentVoiceCaptureDeviceName"] = [](sol::optional<int> deviceId) {
                return lorkhan::VoiceCaptureService::instance().currentDeviceName(deviceId.value_or(-1)); };
            api["voiceCaptureDevices"] = [lua] {
                const auto& capture=lorkhan::VoiceCaptureService::instance();sol::table result(lua,sol::create);
                sol::table mapper(lua,sol::create);mapper["id"]=-1;mapper["name"]=capture.currentDeviceName(-1);result[1]=mapper;
                for(std::size_t id=0;id<capture.deviceCount();++id){sol::table device(lua,sol::create);
                    device["id"]=static_cast<int>(id);device["name"]=capture.currentDeviceName(static_cast<int>(id));
                    result[id+2]=device;}return result; };
            api["submitCapturedStt"] = [lua](const std::string& language) { return client().submitCapturedStt(lua,language); };
            api["pollResults"] = [lua](std::size_t maximum) { return client().poll(lua, maximum); };
            api["prepareMedia"] = [lua](sol::table dto) { return client().prepareMedia(lua, std::move(dto)); };
            api["mediaStatus"] = [lua](const std::string& id) { return client().mediaStatus(lua, id); };
            api["requestMenuDialogueTts"] = [lua](sol::table actor,const std::string& text) {
                return client().requestMenuDialogueTts(lua,std::move(actor),text); };
            api["cancelMenuDialogueTts"] = [](sol::optional<std::string> requestId) {
                return client().cancelMenuDialogueTts(requestId ? std::optional<std::string>(*requestId) : std::nullopt); };
            api["menuDialogueTtsStatus"] = [lua](const std::string& requestId) {
                return client().menuDialogueTtsStatus(lua,requestId); };
            api["requestPlayerAutochat"] = [lua](sol::table player,sol::table target,const std::string& intent) {
                return client().requestPlayerAutochat(lua,std::move(player),std::move(target),intent); };
            api["cancelPlayerAutochat"] = [](sol::optional<std::string> requestId) {
                return client().cancelPlayerAutochat(requestId ? std::optional<std::string>(*requestId) : std::nullopt); };
            api["playerAutochatStatus"] = [lua](const std::string& requestId) {
                return client().playerAutochatStatus(lua,requestId); };
            api["playSpeech"] = [lua, luaManager](const std::string& id, const sol::object& actor,
                                    sol::optional<std::string> subtitle, sol::optional<float> volumeBoost) {
                return client().playSpeech(lua, id, actor, subtitle.value_or(""), volumeBoost.value_or(3.f), luaManager);
            };
            api["showSubtitle"] = [lua, luaManager](const sol::object& actor, const std::string& subtitle) {
                return client().showSubtitle(lua, actor, subtitle, luaManager);
            };
            api["isSpeechActive"] = [](const sol::object& actor) { return client().isSpeechActive(actor); };
            api["stopSpeech"] = [](const sol::object& actor) { return client().stopSpeech(actor); };
            api["actorConversationState"] = [lua](const sol::object& actor) {
                return actorConversationState(lua, actor);
            };
            api["releaseMedia"] = [](const std::string& id) { return client().releaseMedia(id); };
            api["submitActionResult"] = [lua](sol::table dto) { return client().submitActionResult(lua, std::move(dto)); };
            api["submitDialogueDeliveryResult"] = [lua](sol::table dto) {
                return client().submitDialogueDeliveryResult(lua, std::move(dto));
            };
            api["cancelGeneration"] = [](std::uint64_t generation, sol::optional<bool> loadedSave, sol::optional<bool> identityChange) { return client().cancelGeneration(generation,loadedSave.value_or(false),identityChange.value_or(false)); };
            api["finishLoadedSave"] = [](sol::optional<sol::table> calendar) { return client().finishLoadedSave(calendar); };
            api["halt"] = [] { client().halt(); };
            return LuaUtil::makeReadOnly(api);
        }
    }

    bool lorkhanSpellStartAllowed(const MWWorld::Ptr& actor) { return !activeClient||activeClient->spellStartAllowed(actor); }
    void lorkhanSpellStartResult(const MWWorld::Ptr& actor,bool success) { if(activeClient&&!success)activeClient->spellFinished(actor,false,"resource_check_failed"); }
    int lorkhanSpellTarget(const MWWorld::Ptr& actor,MWWorld::Ptr& target) { return activeClient?activeClient->spellTarget(actor,target):0; }
    void lorkhanSpellFinished(const MWWorld::Ptr& actor,bool success) { if(activeClient)activeClient->spellFinished(actor,success); }

    std::optional<LorkhanObservationScope> lorkhanObservationScope()
    {
        return activeClient ? activeClient->observationScope() : std::nullopt;
    }

    sol::object initLorkhanPackage(const Context& context)
    {
        if (context.mType == Context::Menu || context.mType == Context::Load)
            throw std::logic_error("openmw.lorkhan is unavailable in menu and load contexts");
        return makePackage(context.sol(), context.mLuaManager, context.mType == Context::Global);
    }

    sol::object initLorkhanCustomPackageLoader(const Context& context)
    {
        if (context.mType != Context::Local)
            throw std::logic_error("openmw.lorkhan custom loader requires a local context");
        return sol::make_object(context.sol(), [lua = context.mLua, luaManager = context.mLuaManager](sol::table hiddenData) -> sol::object {
            LuaUtil::ScriptId id = hiddenData[LuaUtil::ScriptsContainer::sScriptIdKey];
            if (!lua->getConfiguration().isCustomScript(id.mIndex)) return sol::nil;
            return makePackage(hiddenData.lua_state(), luaManager, false);
        });
    }
}
