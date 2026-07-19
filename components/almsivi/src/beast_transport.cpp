#include "almsivi/beast_transport.hpp"

#ifdef ALMSIVI_WITH_BOOST_BEAST
#include <boost/asio/io_context.hpp>
#include <boost/beast/core/tcp_stream.hpp>

namespace almsivi {

struct BeastTransport::Impl {
    BaseUrl baseUrl;
    PairingToken token;
    boost::asio::io_context context;
};

BeastTransport::BeastTransport(BaseUrl baseUrl, PairingToken token)
    : m_impl(std::make_unique<Impl>(Impl{std::move(baseUrl), std::move(token), {}}))
{
}

BeastTransport::~BeastTransport() = default;

Result<InboundResult> BeastTransport::execute(const OutboundRequest&, std::stop_token)
{
    return Result<InboundResult>::failure(makeError(
        ErrorCode::transport_failure,
        "Beast wire serialization is deferred to the strict protocol slice"));
}

void BeastTransport::interrupt() noexcept
{
    m_impl->context.stop();
}

} // namespace almsivi
#endif
