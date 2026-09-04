#include "lorkhanbindings.hpp"

#include <apps/openmw/mwlua/context.hpp>

#include <lorkhan/beast_transport.hpp>
#include <lorkhan/bridge_service.hpp>
#include <lorkhan/protocol_response.hpp>
#include <lorkhan/validation.hpp>
#include <lorkhan/voice_capture.hpp>
#include <components/lua/configuration.hpp>
#include <components/lua/scriptscontainer.hpp>
#include <components/files/constrainedfilestream.hpp>
#include <components/files/conversion.hpp>
#include <components/settings/values.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/mechanicsmanager.hpp"
#include "../mwbase/soundmanager.hpp"
#include "../mwmechanics/aisequence.hpp"
#include "../mwmechanics/creaturestats.hpp"
#include "../mwworld/class.hpp"

#include "luamanagerimp.hpp"
#include "objectvariant.hpp"

#include <sol/sol.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <ctime>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
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

        public:
            NativeClient()
            {
                try
                {
                    m_config = loadConfig();
                    auto transport = std::make_unique<lorkhan::BeastTransport>(m_config->baseUrl,
                        m_config->installation, lorkhan::PairingToken(m_config->key), m_config->cacheRoot);
                    m_service = std::make_unique<lorkhan::BridgeService>(std::move(transport),
                        std::make_shared<lorkhan::SystemClock>(), processGeneration());
                    beginSession();
                    m_status = "connecting";
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
                    behavior["combat_bark_period_seconds"] = settings.behavior.combatBarkPeriodSeconds;
                    memory["recent_turn_limit"] = settings.memory.recentTurnLimit;
                    memory["knowledge_limit"] = settings.memory.knowledgeLimit;
                    narrator["enabled"] = settings.narrator.enabled;
                    narrator["name"] = settings.narrator.name;
                    narrator["context_visibility"] = settings.narrator.contextVisibility;
                    narrator["inline_mode"] = settings.narrator.inlineMode;
                    narrator["welcome_events"] = settings.narrator.welcomeEvents;
                    narrator["random_events"] = settings.narrator.randomEvents;
                    narrator["quest_events"] = settings.narrator.questEvents;
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

            std::tuple<sol::object, sol::object> submitActorProfile(sol::state_view lua, sol::table payload)
            {
                return submitGameData(lua, lorkhan::GameDataType::actor_profile, std::move(payload));
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
                behavior["combat_bark_period_seconds"]=snapshot.behavior.combatBarkPeriodSeconds;
                memory["recent_turn_limit"]=snapshot.memory.recentTurnLimit;memory["knowledge_limit"]=snapshot.memory.knowledgeLimit;
                narrator["enabled"]=snapshot.narrator.enabled;narrator["name"]=snapshot.narrator.name;
                narrator["context_visibility"]=snapshot.narrator.contextVisibility;narrator["inline_mode"]=snapshot.narrator.inlineMode;
                narrator["welcome_events"]=snapshot.narrator.welcomeEvents;narrator["random_events"]=snapshot.narrator.randomEvents;
                narrator["quest_events"]=snapshot.narrator.questEvents;narrator["book_events"]=snapshot.narrator.bookEvents;
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

            sol::object mediaStatus(sol::state_view lua, const std::string& mediaId) const
            {
                const auto found = m_media.find(mediaId);
                if (found == m_media.end()) return sol::make_object(lua, sol::nil);
                  sol::table result(lua, sol::create); result["state"] = found->second.state;
                  if (!found->second.reason.empty()) result["reason"] = found->second.reason;
                  return sol::make_object(lua, result);
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
                            dto.get<std::string>("reason_code"), toJson(dto.get<sol::object>("observed")),
                            dto.get<std::string>("completed_at") } };
                    auto accepted = m_service->enqueue(std::move(request));
                    if (!accepted) return failure(lua, accepted.error().message);
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
                        std::visit([&](const auto& parameter){parameters[key]=parameter;},value);
                    }
                    command["parameters"]=parameters;status["command"]=command;
                    m_debugCommand.reset();}
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
                    ++m_resultsSeen;
                    if (settleDebugResult(result)) continue;
                    if (result.kind == lorkhan::ResponseKind::failure)
                    {
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
                                for (const auto& event : parsed.value().events)
                                    output[outIndex++] = eventTable(lua, event);
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
                schedulePoll();
                return output;
            }

            bool cancelGeneration(std::uint64_t generation)
            {
                if (!m_service) return false;
                auto result = m_service->cancelGeneration(lorkhan::Generation(generation));
                if (!result) return false;
                cancelMenuDialogueTts();
                m_session.reset(); m_clientSettings.reset(); m_configRevision.clear();
                m_pollRequest.reset(); m_initRequest.reset();m_controlsRequest.reset();m_controls.reset();
                m_debugRequest.reset();m_debugCommand.reset();m_deferredResults.clear();m_turnRequests.clear();m_controlsError.clear();m_debugError.clear();beginSession();
                m_status = "connecting";
                return true;
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
                if (!m_service || !m_config || m_initRequest) return;
                const lorkhan::RequestId request(uuid());
                lorkhan::EnvelopeIds ids{ m_config->installation, m_config->profile, m_config->playthrough, {}, request,
                    lorkhan::TurnId(uuid()), lorkhan::MessageId(uuid()), m_service->generation() };
                lorkhan::RuntimeInfo runtime; runtime.platform = m_config->platform;
                runtime.capabilities = capabilities();
                lorkhan::OutboundRequest outbound{ request, {}, ids.generation, lorkhan::RequestKind::init,
                    lorkhan::InitRequest{ std::move(ids), std::move(runtime), m_config->fingerprint, utcNow() } };
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
            { return { "dialogue.text", "speech.say", "speech.listen", "controls.session", "debug.commands.v1", "action.ai.follow", "action.ai.stop",
                "action.ai.approach", "action.ai.wait", "action.ai.travel", "action.ai.escort", "action.ai.face", "action.ai.wander", "action.combat.start",
                "action.combat.stop", "action.animation.play", "action.item.equip", "action.item.unequip", "action.item.use",
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
                            case lorkhan::ActionIntentKind::ai_approach: name = "ai.approach"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_wait: name = "ai.wait"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_travel: name = "ai.travel"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_escort: name = "ai.escort"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_face: name = "ai.face"; tier = 1; break;
                            case lorkhan::ActionIntentKind::ai_wander: name = "ai.wander"; tier = 1; break;
                            case lorkhan::ActionIntentKind::animation_play: name = "animation.play"; tier = 1; break;
                            case lorkhan::ActionIntentKind::combat_start: name = "combat.start"; tier = 2; break;
                            case lorkhan::ActionIntentKind::combat_stop: name = "combat.stop"; tier = 1; break;
                            case lorkhan::ActionIntentKind::inspect_report: break;
                            case lorkhan::ActionIntentKind::inventory_inspect: name = "inventory.inspect"; break;
                            case lorkhan::ActionIntentKind::item_equip: name = "item.equip"; tier = 2; break;
                            case lorkhan::ActionIntentKind::item_unequip: name = "item.unequip"; tier = 2; break;
                            case lorkhan::ActionIntentKind::item_use: name = "item.use"; tier = 2; break;
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
                        payload["parameters"] = parameters;
                        if (!item.displayName.empty()) payload["display_name"] = item.displayName;
                        if (item.confirmationRequired) payload["confirmation_required"] = *item.confirmationRequired;
                        if (item.followupEnabled) payload["followup_enabled"] = *item.followupEnabled;
                        if (item.followupActionsAllowed) payload["followup_actions_allowed"] = *item.followupActionsAllowed;
                        if (item.followupDepth) payload["followup_depth"] = *item.followupDepth;
                        payload["expires_at"] = item.expiresAt; break; }
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
            std::unique_ptr<lorkhan::BridgeService> m_service;
            std::optional<lorkhan::SessionId> m_session;
            std::optional<lorkhan::ClientSettings> m_clientSettings;
            std::string m_configRevision;
            std::optional<lorkhan::RequestId> m_initRequest;
            std::optional<lorkhan::RequestId> m_pollRequest;
            std::optional<lorkhan::RequestId> m_controlsRequest;
            std::optional<lorkhan::ControlsResponse> m_controls;
            std::string m_controlsError;
            std::optional<lorkhan::RequestId> m_debugRequest;
            std::optional<lorkhan::DebugCommandResponse::Command> m_debugCommand;
            std::string m_debugError;
            static constexpr std::size_t kControlsPumpBatch = 8;
            static constexpr std::size_t kDeferredResultCapacity = lorkhan::kInboundCapacity;
            std::vector<lorkhan::InboundResult> m_deferredResults;
            std::map<std::string,std::string> m_turnRequests;
            std::uint64_t m_cursor{};
            std::chrono::steady_clock::time_point m_nextPoll{};
            std::map<std::string, MediaState> m_media;
            std::map<std::string, MenuDialogueState> m_menuDialogues;
            std::string m_status{"unconfigured"};
            std::string m_error;
            std::uint64_t m_resultsSeen{};
            std::uint64_t m_initMatches{};
        };

        NativeClient& client()
        {
            static NativeClient instance;
            return instance;
        }

        sol::object makePackage(sol::state_view lua, LuaManager* luaManager)
        {
            sol::table api(lua, sol::create);
            api["version"] = std::string(lorkhan::kClientVersion);
            api["capabilities"] = [lua] {
                sol::table result(lua, sol::create); std::size_t index = 1;
            for (const auto& capability : std::vector<std::string>{ "dialogue.text", "speech.say", "speech.listen", "controls.session",
                "action.ai.follow", "action.ai.stop", "action.ai.approach", "action.ai.wait", "action.ai.travel", "action.ai.escort", "action.ai.face", "action.ai.wander",
                "action.combat.start", "action.combat.stop", "action.animation.play", "action.item.equip", "action.item.unequip",
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
            api["submitActorProfile"] = [lua](sol::table payload) {
                return client().submitActorProfile(lua, std::move(payload));
            };
            api["requestSessionControls"] = [lua](sol::table target) { return client().requestControls(lua,std::move(target)); };
            api["selectSessionControl"] = [lua](const std::string& kind,sol::optional<std::string> selection,sol::table target) {
                return client().selectControl(lua,kind,std::move(selection),std::move(target));
            };
            api["sessionControls"] = [lua] { return client().sessionControls(lua); };
            api["pumpSessionControls"] = [lua] { return client().pumpSessionControls(lua); };
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
            api["cancelGeneration"] = [](std::uint64_t generation) { return client().cancelGeneration(generation); };
            api["halt"] = [] { client().halt(); };
            return LuaUtil::makeReadOnly(api);
        }
    }

    sol::object initLorkhanPackage(const Context& context)
    {
        if (context.mType == Context::Menu || context.mType == Context::Load)
            throw std::logic_error("openmw.lorkhan is unavailable in menu and load contexts");
        return makePackage(context.sol(), context.mLuaManager);
    }

    sol::object initLorkhanCustomPackageLoader(const Context& context)
    {
        if (context.mType != Context::Local)
            throw std::logic_error("openmw.lorkhan custom loader requires a local context");
        return sol::make_object(context.sol(), [lua = context.mLua, luaManager = context.mLuaManager](sol::table hiddenData) -> sol::object {
            LuaUtil::ScriptId id = hiddenData[LuaUtil::ScriptsContainer::sScriptIdKey];
            if (!lua->getConfiguration().isCustomScript(id.mIndex)) return sol::nil;
            return makePackage(hiddenData.lua_state(), luaManager);
        });
    }
}
