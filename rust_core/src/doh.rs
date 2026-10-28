use std::collections::HashSet;
use std::fmt;
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use reqwest::Client;

use crate::error::CoreError;

pub(super) const DOH_ENDPOINT: &str = "https://cloudflare-dns.com/dns-query";
const DOH_HOST: &str = "cloudflare-dns.com";
const DOH_MAX_RESPONSE_BYTES: u64 = 64 * 1024;
const DNS_RESOLUTION_TIMEOUT: Duration = Duration::from_secs(5);
const DOH_CYCLE_TIMEOUT: Duration = Duration::from_secs(10);
const DOH_BOOTSTRAP_ADDRS: [SocketAddr; 2] = [
    SocketAddr::new(IpAddr::V4(std::net::Ipv4Addr::new(1, 1, 1, 1)), 443),
    SocketAddr::new(IpAddr::V4(std::net::Ipv4Addr::new(1, 0, 0, 1)), 443),
];

#[allow(clippy::upper_case_acronyms)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum QueryType {
    A,
    AAAA,
}

impl QueryType {
    pub(super) const fn as_u16(self) -> u16 {
        match self {
            Self::A => 1,
            Self::AAAA => 28,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum DnsFailureClass {
    Timeout,
    NoAddress,
    Temporary,
    Other,
    Tls,
    Http,
    Payload,
    Rcode,
    EndpointUnreachable,
    TcpConnect,
    NotAttempted,
}

impl DnsFailureClass {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Timeout => "dns_timeout",
            Self::NoAddress => "dns_no_address",
            Self::Temporary => "dns_temporary",
            Self::Other => "dns_other",
            Self::Tls => "tls_handshake",
            Self::Http => "doh_http_status",
            Self::Payload => "dns_payload_invalid",
            Self::Rcode => "dns_rcode",
            Self::EndpointUnreachable => "doh_endpoint_unreachable",
            Self::TcpConnect => "tcp_connect",
            Self::NotAttempted => "not_attempted",
        }
    }

    pub(super) const fn allows_doh_fallback(self) -> bool {
        matches!(self, Self::Timeout | Self::NoAddress | Self::Temporary)
    }
}

impl fmt::Display for DnsFailureClass {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

pub(super) fn is_allowed_nxapi_host(host: &str) -> bool {
    matches!(
        host.to_ascii_lowercase().as_str(),
        "nxapi-auth.fancy.org.uk" | "nxapi-znca-api.fancy.org.uk"
    )
}

pub(super) fn nxapi_host_class(host: &str) -> Option<&'static str> {
    match host.to_ascii_lowercase().as_str() {
        "nxapi-auth.fancy.org.uk" | "nxapi-znca-api.fancy.org.uk" => Some("nxapi"),
        _ => None,
    }
}

pub(super) fn classify_system_error(error: &io::Error) -> DnsFailureClass {
    match error.kind() {
        io::ErrorKind::TimedOut => DnsFailureClass::Timeout,
        io::ErrorKind::NotFound | io::ErrorKind::AddrNotAvailable => DnsFailureClass::NoAddress,
        io::ErrorKind::Interrupted
        | io::ErrorKind::WouldBlock
        | io::ErrorKind::ConnectionAborted
        | io::ErrorKind::ConnectionReset => DnsFailureClass::Temporary,
        _ => {
            let message = error.to_string().to_ascii_lowercase();
            if message.contains("name or service not known")
                || message.contains("nodename nor servname")
                || message.contains("no such host")
            {
                return DnsFailureClass::NoAddress;
            }
            if message.contains("temporary failure")
                || message.contains("try again")
                || message.contains("temporarily unavailable")
            {
                return DnsFailureClass::Temporary;
            }
            match error.raw_os_error() {
                // Windows getaddrinfo/WSA errors.
                Some(10060) => DnsFailureClass::Timeout,
                Some(11001 | 11004) => DnsFailureClass::NoAddress,
                Some(11002) => DnsFailureClass::Temporary,
                // POSIX EAI_AGAIN and EAI_NONAME commonly surface as these
                // values through platform resolver adapters.
                Some(-3) => DnsFailureClass::NoAddress,
                Some(-2) => DnsFailureClass::Temporary,
                _ => DnsFailureClass::Other,
            }
        }
    }
}

pub(super) fn classify_doh_error(error: &reqwest::Error) -> DnsFailureClass {
    if error.is_timeout()
        || doh_io_error_kind(error).is_some_and(|kind| kind == io::ErrorKind::TimedOut)
    {
        DnsFailureClass::EndpointUnreachable
    } else if is_tls_error(&error.to_string()) {
        DnsFailureClass::Tls
    } else if error.is_connect()
        || doh_io_error_kind(error).is_some_and(|kind| {
            matches!(
                kind,
                io::ErrorKind::ConnectionAborted
                    | io::ErrorKind::ConnectionRefused
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::BrokenPipe
                    | io::ErrorKind::NotConnected
                    | io::ErrorKind::UnexpectedEof
            )
        })
    {
        DnsFailureClass::TcpConnect
    } else if error.is_request() || error.is_body() || error.is_decode() || error.is_redirect() {
        // A failed DoH HTTP exchange is an endpoint/transport failure. Only a
        // successfully received 200 response can be classified as bad DNS
        // payload by the response parser.
        DnsFailureClass::EndpointUnreachable
    } else {
        DnsFailureClass::Other
    }
}

fn doh_io_error_kind(error: &reqwest::Error) -> Option<io::ErrorKind> {
    let mut source: Option<&(dyn std::error::Error + 'static)> = Some(error);
    while let Some(cause) = source {
        if let Some(io_error) = cause.downcast_ref::<io::Error>() {
            return Some(io_error.kind());
        }
        source = cause.source();
    }
    None
}

pub(super) fn is_tls_error(message: &str) -> bool {
    let message = message.to_ascii_lowercase();
    [
        "tls",
        "handshake",
        "certificate",
        "invalid peer",
        "unknown issuer",
    ]
    .iter()
    .any(|marker| message.contains(marker))
}

async fn bounded<T, F>(future: F) -> Result<T, DnsFailureClass>
where
    F: Future<Output = T>,
{
    bounded_with_timeout(future, DNS_RESOLUTION_TIMEOUT).await
}

async fn bounded_with_timeout<T, F>(future: F, timeout: Duration) -> Result<T, DnsFailureClass>
where
    F: Future<Output = T>,
{
    tokio::time::timeout(timeout, future)
        .await
        .map_err(|_| DnsFailureClass::Timeout)
}

pub(super) async fn system_lookup(
    host: &str,
    port: u16,
) -> Result<Vec<SocketAddr>, DnsFailureClass> {
    let addresses = bounded(tokio::net::lookup_host((host, port)))
        .await?
        .map_err(|error| classify_system_error(&error))?
        .collect::<Vec<_>>();
    if addresses.is_empty() {
        Err(DnsFailureClass::NoAddress)
    } else {
        Ok(addresses)
    }
}

pub(super) async fn resolve_via_doh(
    client: &Client,
    endpoint: &str,
    host: &str,
    port: u16,
) -> Result<Vec<SocketAddr>, DnsFailureClass> {
    match bounded_with_timeout(
        resolve_via_doh_inner(client, endpoint, host, port),
        DOH_CYCLE_TIMEOUT,
    )
    .await
    {
        Ok(result) => result,
        Err(_) => Err(DnsFailureClass::EndpointUnreachable),
    }
}

async fn resolve_via_doh_inner(
    client: &Client,
    endpoint: &str,
    host: &str,
    port: u16,
) -> Result<Vec<SocketAddr>, DnsFailureClass> {
    let mut addresses = Vec::new();
    let mut seen = HashSet::new();
    for query_type in [QueryType::A, QueryType::AAAA] {
        let id = rand::random::<u16>();
        let query = build_query(host, query_type, id).map_err(|_| DnsFailureClass::Payload)?;
        let response = client
            .post(endpoint)
            .header("content-type", "application/dns-message")
            .header("accept", "application/dns-message")
            .body(query)
            .send()
            .await
            .map_err(|error| classify_doh_error(&error))?;
        if !response.status().is_success() {
            return Err(DnsFailureClass::Http);
        }
        if !response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| {
                value.split(';').next().is_some_and(|media_type| {
                    media_type
                        .trim()
                        .eq_ignore_ascii_case("application/dns-message")
                })
            })
        {
            return Err(DnsFailureClass::Payload);
        }
        if response
            .content_length()
            .is_some_and(|length| length > DOH_MAX_RESPONSE_BYTES)
        {
            return Err(DnsFailureClass::Payload);
        }
        let body = response
            .bytes()
            .await
            .map_err(|error| classify_doh_error(&error))?;
        if body.len() as u64 > DOH_MAX_RESPONSE_BYTES {
            return Err(DnsFailureClass::Payload);
        }
        for address in parse_response(&body, host, id, query_type)? {
            if seen.insert(address) {
                addresses.push(SocketAddr::new(address, port));
            }
        }
    }
    if addresses.is_empty() {
        Err(DnsFailureClass::NoAddress)
    } else {
        Ok(addresses)
    }
}

pub(super) fn bootstrap_addresses() -> &'static [SocketAddr] {
    &DOH_BOOTSTRAP_ADDRS
}

pub(super) const fn doh_host() -> &'static str {
    DOH_HOST
}

pub(super) fn build_query(
    host: &str,
    query_type: QueryType,
    id: u16,
) -> Result<Vec<u8>, DnsFailureClass> {
    let host = host.trim_end_matches('.');
    if host.is_empty() || host.len() > 253 {
        return Err(DnsFailureClass::Payload);
    }
    let mut output = Vec::with_capacity(64);
    output.extend_from_slice(&id.to_be_bytes());
    output.extend_from_slice(&[0x01, 0x00]); // RD
    output.extend_from_slice(&[0x00, 0x01]); // QDCOUNT
    output.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    for label in host.split('.') {
        if label.is_empty() || label.len() > 63 || !label.is_ascii() {
            return Err(DnsFailureClass::Payload);
        }
        output.push(label.len() as u8);
        output.extend_from_slice(label.as_bytes());
    }
    output.push(0);
    output.extend_from_slice(&query_type.as_u16().to_be_bytes());
    output.extend_from_slice(&[0x00, 0x01]); // IN
    Ok(output)
}

fn parse_name(data: &[u8], offset: usize) -> Result<(String, usize), DnsFailureClass> {
    let mut cursor = offset;
    let mut next = offset;
    let mut jumped = false;
    let mut labels = Vec::new();
    let mut jumps = 0;
    loop {
        let length = *data.get(cursor).ok_or(DnsFailureClass::Payload)?;
        if length == 0 {
            if !jumped {
                next = cursor + 1;
            }
            break;
        }
        if length & 0xc0 == 0xc0 {
            let second = *data.get(cursor + 1).ok_or(DnsFailureClass::Payload)?;
            let pointer = (((length as usize) & 0x3f) << 8) | second as usize;
            if pointer >= cursor || pointer >= data.len() || jumps >= 16 {
                return Err(DnsFailureClass::Payload);
            }
            if !jumped {
                next = cursor + 2;
                jumped = true;
            }
            cursor = pointer;
            jumps += 1;
            continue;
        }
        if length & 0xc0 != 0 || length > 63 {
            return Err(DnsFailureClass::Payload);
        }
        let end = cursor
            .checked_add(1 + length as usize)
            .ok_or(DnsFailureClass::Payload)?;
        let label = data.get(cursor + 1..end).ok_or(DnsFailureClass::Payload)?;
        if !label.is_ascii() {
            return Err(DnsFailureClass::Payload);
        }
        labels.push(String::from_utf8(label.to_vec()).map_err(|_| DnsFailureClass::Payload)?);
        cursor = end;
        if !jumped {
            next = cursor;
        }
        if labels.iter().map(String::len).sum::<usize>() + labels.len() > 253 {
            return Err(DnsFailureClass::Payload);
        }
    }
    Ok((labels.join("."), next))
}

#[cfg(test)]
pub(super) fn parse_query_name(
    data: &[u8],
    offset: usize,
) -> Result<(String, usize), DnsFailureClass> {
    parse_name(data, offset)
}

pub(super) fn parse_response(
    data: &[u8],
    expected_name: &str,
    expected_id: u16,
    query_type: QueryType,
) -> Result<Vec<IpAddr>, DnsFailureClass> {
    if data.len() < 12 {
        return Err(DnsFailureClass::Payload);
    }
    if u16::from_be_bytes([data[0], data[1]]) != expected_id {
        return Err(DnsFailureClass::Payload);
    }
    let flags = u16::from_be_bytes([data[2], data[3]]);
    if flags & 0x8000 == 0 || flags & 0x0200 != 0 || flags & 0x0040 != 0 || flags & 0x7800 != 0 {
        return Err(DnsFailureClass::Payload);
    }
    if flags & 0x000f != 0 {
        return Err(DnsFailureClass::Rcode);
    }
    let questions = u16::from_be_bytes([data[4], data[5]]);
    if questions != 1 {
        return Err(DnsFailureClass::Payload);
    }
    let answer_count = u16::from_be_bytes([data[6], data[7]]) as usize;
    let authority_count = u16::from_be_bytes([data[8], data[9]]) as usize;
    let additional_count = u16::from_be_bytes([data[10], data[11]]) as usize;
    let (question_name, mut cursor) = parse_name(data, 12)?;
    let question_end = cursor.checked_add(4).ok_or(DnsFailureClass::Payload)?;
    if question_end > data.len() {
        return Err(DnsFailureClass::Payload);
    }
    if !question_name.eq_ignore_ascii_case(expected_name)
        || u16::from_be_bytes([data[cursor], data[cursor + 1]]) != query_type.as_u16()
        || u16::from_be_bytes([data[cursor + 2], data[cursor + 3]]) != 1
    {
        return Err(DnsFailureClass::Payload);
    }
    cursor = question_end;

    let total_records = answer_count
        .checked_add(authority_count)
        .and_then(|value| value.checked_add(additional_count))
        .ok_or(DnsFailureClass::Payload)?;
    let mut answer_records = Vec::with_capacity(answer_count);
    for index in 0..total_records {
        let (record_name, next) = parse_name(data, cursor)?;
        cursor = next;
        let record_type = read_u16(data, &mut cursor)?;
        let record_class = read_u16(data, &mut cursor)?;
        let _ttl = read_u32(data, &mut cursor)?;
        let length = read_u16(data, &mut cursor)? as usize;
        let end = cursor.checked_add(length).ok_or(DnsFailureClass::Payload)?;
        data.get(cursor..end).ok_or(DnsFailureClass::Payload)?;
        if index < answer_count && record_class == 1 {
            answer_records.push((record_name, record_type, cursor, end));
        }
        cursor = end;
    }
    if cursor != data.len() {
        return Err(DnsFailureClass::Payload);
    }

    let mut current_name = expected_name.to_ascii_lowercase();
    let mut cname_chain = HashSet::new();
    cname_chain.insert(current_name.clone());
    loop {
        let mut cname_target = None;
        for (name, record_type, start, end) in &answer_records {
            if name.eq_ignore_ascii_case(&current_name) && *record_type == 5 {
                let (target, consumed) = parse_name(data, *start)?;
                if consumed != *end {
                    return Err(DnsFailureClass::Payload);
                }
                if cname_target
                    .as_ref()
                    .is_some_and(|existing: &String| !existing.eq_ignore_ascii_case(&target))
                {
                    return Err(DnsFailureClass::Payload);
                }
                cname_target = Some(target.to_ascii_lowercase());
            }
        }
        if let Some(target) = cname_target {
            if !cname_chain.insert(target.clone()) || cname_chain.len() > 16 {
                return Err(DnsFailureClass::Payload);
            }
            current_name = target;
        } else {
            break;
        }
    }

    let mut addresses = Vec::new();
    for (name, record_type, start, end) in answer_records {
        if !name.eq_ignore_ascii_case(&current_name) || record_type != query_type.as_u16() {
            continue;
        }
        let payload = data.get(start..end).ok_or(DnsFailureClass::Payload)?;
        let address = match query_type {
            QueryType::A if payload.len() == 4 => IpAddr::V4(std::net::Ipv4Addr::new(
                payload[0], payload[1], payload[2], payload[3],
            )),
            QueryType::AAAA if payload.len() == 16 => {
                let mut octets = [0_u8; 16];
                octets.copy_from_slice(payload);
                IpAddr::V6(std::net::Ipv6Addr::from(octets))
            }
            _ => return Err(DnsFailureClass::Payload),
        };
        addresses.push(address);
    }
    Ok(addresses)
}

fn read_u16(data: &[u8], cursor: &mut usize) -> Result<u16, DnsFailureClass> {
    let end = cursor.checked_add(2).ok_or(DnsFailureClass::Payload)?;
    let bytes = data.get(*cursor..end).ok_or(DnsFailureClass::Payload)?;
    *cursor = end;
    Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
}

fn read_u32(data: &[u8], cursor: &mut usize) -> Result<u32, DnsFailureClass> {
    let end = cursor.checked_add(4).ok_or(DnsFailureClass::Payload)?;
    let bytes = data.get(*cursor..end).ok_or(DnsFailureClass::Payload)?;
    *cursor = end;
    Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

pub(super) fn combined_dns_error(
    stage: &'static str,
    url: &str,
    proxy: &'static str,
    elapsed_ms: u64,
    system: DnsFailureClass,
    doh: DnsFailureClass,
) -> CoreError {
    CoreError::NetworkRequest {
        stage,
        reason: "dns_failed",
        proxy,
        elapsed_ms,
        url: url.to_owned(),
        code_kind: "dns",
        code: format!("system={system} doh={doh}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    #[test]
    fn nxapi_allowlist_accepts_only_the_two_exact_hosts() {
        assert!(is_allowed_nxapi_host("nxapi-auth.fancy.org.uk"));
        assert!(is_allowed_nxapi_host("NXAPI-ZNCA-API.FANCY.ORG.UK"));
        assert!(!is_allowed_nxapi_host("nxapi-auth.fancy.org.uk."));
        assert!(!is_allowed_nxapi_host("example.nxapi-auth.fancy.org.uk"));
        assert!(!is_allowed_nxapi_host("nxapi-auth.fancy.org.uk.evil"));
        assert!(!is_allowed_nxapi_host("fancy.org.uk"));
        assert!(bootstrap_addresses()
            .iter()
            .all(|address| address.port() == 443));
    }

    #[test]
    fn dns_query_wire_format_contains_one_question_for_the_requested_type() {
        let query = build_query("nxapi-auth.fancy.org.uk", QueryType::A, 0x1234).unwrap();
        assert_eq!(&query[0..2], &[0x12, 0x34]);
        assert_eq!(&query[2..4], &[0x01, 0x00]);
        assert_eq!(&query[4..12], &[0, 1, 0, 0, 0, 0, 0, 0]);
        assert_eq!(
            parse_query_name(&query, 12).unwrap().0,
            "nxapi-auth.fancy.org.uk"
        );
        let end = parse_query_name(&query, 12).unwrap().1;
        assert_eq!(&query[end..end + 4], &[0, 1, 0, 1]);
    }

    #[test]
    fn dns_response_parser_extracts_a_and_aaaa_records_and_rejects_bad_payloads() {
        let a = synthetic_dns_response(0x1234, QueryType::A, [192, 0, 2, 1].as_slice());
        assert_eq!(
            parse_response(&a, "example.com", 0x1234, QueryType::A).unwrap(),
            vec!["192.0.2.1".parse::<IpAddr>().unwrap()]
        );

        let aaaa = synthetic_dns_response(
            0x1234,
            QueryType::AAAA,
            &[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        );
        assert_eq!(
            parse_response(&aaaa, "example.com", 0x1234, QueryType::AAAA).unwrap(),
            vec!["2001:db8::1".parse::<IpAddr>().unwrap()]
        );

        let mut malformed = a;
        malformed.truncate(malformed.len() - 1);
        assert!(parse_response(&malformed, "example.com", 0x1234, QueryType::A).is_err());
    }

    #[test]
    fn only_explicit_dns_failures_are_eligible_for_one_doh_fallback() {
        assert!(DnsFailureClass::Timeout.allows_doh_fallback());
        assert!(DnsFailureClass::NoAddress.allows_doh_fallback());
        assert!(DnsFailureClass::Temporary.allows_doh_fallback());
        assert!(!DnsFailureClass::Other.allows_doh_fallback());
        assert!(!DnsFailureClass::Tls.allows_doh_fallback());
        assert!(!DnsFailureClass::Http.allows_doh_fallback());
        assert!(!DnsFailureClass::Rcode.allows_doh_fallback());
        assert!(!DnsFailureClass::EndpointUnreachable.allows_doh_fallback());
        assert!(!DnsFailureClass::TcpConnect.allows_doh_fallback());
    }

    #[test]
    fn system_resolver_errors_map_known_name_failures_without_echoing_their_text() {
        assert_eq!(
            classify_system_error(&std::io::Error::other("Name or service not known")),
            DnsFailureClass::NoAddress
        );
        assert_eq!(
            classify_system_error(&std::io::Error::other(
                "temporary failure in name resolution",
            )),
            DnsFailureClass::Temporary
        );
        assert_eq!(
            classify_system_error(&std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "private resolver detail",
            )),
            DnsFailureClass::Other
        );
    }

    #[test]
    fn combined_dns_error_contains_only_fixed_system_and_doh_classes() {
        let error = combined_dns_error(
            "nxapi_oauth",
            "https://nxapi-auth.fancy.org.uk/api/oauth/token",
            "default",
            7,
            DnsFailureClass::Timeout,
            DnsFailureClass::Payload,
        );
        let message = error.to_string();
        assert!(
            message.contains("system=dns_timeout doh=dns_payload_invalid"),
            "{message}"
        );
        assert!(!message.contains("nxapi-auth.fancy.org.uk/api/oauth/token?"));
        assert!(!message.contains("private"));
    }

    #[tokio::test]
    async fn system_resolution_budget_maps_elapsed_lookup_to_timeout() {
        let result = bounded_with_timeout(
            tokio::time::sleep(Duration::from_millis(100)),
            Duration::from_millis(1),
        )
        .await;
        assert_eq!(result, Err(DnsFailureClass::Timeout));
    }

    #[tokio::test]
    async fn doh_uses_wireformat_post_and_keeps_resolved_target_port() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/dns-query", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut request = Vec::new();
                let mut buffer = [0_u8; 1024];
                while !request.windows(4).any(|value| value == b"\r\n\r\n") {
                    let read = stream.read(&mut buffer).unwrap();
                    assert!(read > 0);
                    request.extend_from_slice(&buffer[..read]);
                }
                let header_end = request
                    .windows(4)
                    .position(|value| value == b"\r\n\r\n")
                    .unwrap()
                    + 4;
                let headers = String::from_utf8(request[..header_end].to_vec()).unwrap();
                let length = headers
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse::<usize>().unwrap())
                    })
                    .unwrap();
                while request.len() < header_end + length {
                    let read = stream.read(&mut buffer).unwrap();
                    assert!(read > 0);
                    request.extend_from_slice(&buffer[..read]);
                }
                let query = &request[header_end..header_end + length];
                let query_type = parse_query_type(query).unwrap();
                let response = synthetic_response_from_query(query, query_type);
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    response.len()
                )
                .unwrap();
                stream.write_all(&response).unwrap();
                requests.push((headers, query.to_vec()));
            }
            requests
        });

        let client = Client::builder().no_proxy().build().unwrap();
        let addresses = resolve_via_doh(&client, &endpoint, "example.com", 4433)
            .await
            .unwrap();
        let requests = server.join().unwrap();
        assert_eq!(addresses.len(), 2);
        assert!(addresses.contains(&"192.0.2.9:4433".parse().unwrap()));
        assert!(addresses.contains(&"[2001:db8::9]:4433".parse().unwrap()));
        assert_eq!(requests.len(), 2);
        for (headers, query) in requests {
            assert!(headers.starts_with("POST /dns-query HTTP/1.1"));
            assert!(headers
                .lines()
                .any(|line| line.eq_ignore_ascii_case("content-type: application/dns-message")));
            assert_eq!(u16::from_be_bytes([query[4], query[5]]), 1);
        }
    }

    #[tokio::test]
    async fn doh_http_status_and_payload_errors_keep_distinct_classes() {
        let client = Client::builder().no_proxy().build().unwrap();
        let (endpoint, server) = doh_http_response(503, "application/json", "private response");
        assert_eq!(
            resolve_via_doh(&client, &endpoint, "example.com", 443).await,
            Err(DnsFailureClass::Http)
        );
        server.join().unwrap();

        let (endpoint, server) = doh_http_response(200, "application/json", "not a DNS packet");
        assert_eq!(
            resolve_via_doh(&client, &endpoint, "example.com", 443).await,
            Err(DnsFailureClass::Payload)
        );
        server.join().unwrap();
    }

    fn doh_http_response(
        status: u16,
        content_type: &'static str,
        body: &'static str,
    ) -> (String, std::thread::JoinHandle<()>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/dns-query", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            use std::io::{Read, Write};

            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut request = Vec::new();
            let mut buffer = [0_u8; 1024];
            let header_end = loop {
                let read = stream.read(&mut buffer).unwrap();
                assert!(read > 0);
                request.extend_from_slice(&buffer[..read]);
                if let Some(index) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                    break index + 4;
                }
            };
            let headers = std::str::from_utf8(&request[..header_end]).unwrap();
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().unwrap())
                })
                .unwrap();
            while request.len() < header_end + content_length {
                let read = stream.read(&mut buffer).unwrap();
                assert!(read > 0);
                request.extend_from_slice(&buffer[..read]);
            }
            write!(
                stream,
                "HTTP/1.1 {status} Test\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        (endpoint, server)
    }

    #[test]
    fn response_parser_rejects_question_mismatch_and_nonzero_rcode() {
        let response = synthetic_dns_response(0x1234, QueryType::A, [192, 0, 2, 1].as_slice());
        assert_eq!(
            parse_response(&response, "other.example", 0x1234, QueryType::A),
            Err(DnsFailureClass::Payload)
        );
        let mut nxdomain = response;
        nxdomain[3] |= 0x03;
        assert_eq!(
            parse_response(&nxdomain, "example.com", 0x1234, QueryType::A),
            Err(DnsFailureClass::Rcode)
        );
        let mut reserved_bit =
            synthetic_dns_response(0x1234, QueryType::A, [192, 0, 2, 1].as_slice());
        reserved_bit[3] |= 0x40;
        assert_eq!(
            parse_response(&reserved_bit, "example.com", 0x1234, QueryType::A),
            Err(DnsFailureClass::Payload)
        );
    }

    #[test]
    fn response_parser_rejects_compression_pointer_cycles() {
        let mut response = build_query("example.com", QueryType::A, 0x1234).unwrap();
        response[2] = 0x81;
        response[3] = 0x80;
        response[6] = 0;
        response[7] = 1;
        let record_name_offset = response.len();
        response.extend_from_slice(&[
            0xc0 | ((record_name_offset >> 8) as u8 & 0x3f),
            record_name_offset as u8,
        ]);

        assert_eq!(
            parse_response(&response, "example.com", 0x1234, QueryType::A),
            Err(DnsFailureClass::Payload)
        );
    }

    #[test]
    fn response_parser_rejects_forward_compression_pointers() {
        let mut response = build_query("example.com", QueryType::A, 0x1234).unwrap();
        response[2] = 0x81;
        response[3] = 0x80;
        response[6] = 0;
        response[7] = 1;
        let record_name_offset = response.len();
        response.extend_from_slice(&[
            0xc0 | (((record_name_offset + 2) >> 8) as u8 & 0x3f),
            (record_name_offset + 2) as u8,
        ]);
        assert_eq!(
            parse_response(&response, "example.com", 0x1234, QueryType::A),
            Err(DnsFailureClass::Payload)
        );
    }

    #[tokio::test]
    async fn doh_request_errors_never_misclassify_transport_failures_as_bad_dns_payloads() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let _ = listener.accept();
            std::thread::sleep(Duration::from_millis(100));
        });
        let client = Client::builder()
            .no_proxy()
            .timeout(Duration::from_millis(1))
            .build()
            .unwrap();
        let timeout_error = client
            .get(format!("http://{address}/dns-query"))
            .send()
            .await
            .unwrap_err();
        assert_eq!(
            classify_doh_error(&timeout_error),
            DnsFailureClass::EndpointUnreachable
        );
        server.join().unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let connect_client = Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(2))
            .build()
            .unwrap();
        let connect_error = connect_client
            .get(format!("http://{address}/dns-query"))
            .send()
            .await
            .unwrap_err();
        assert!(matches!(
            classify_doh_error(&connect_error),
            DnsFailureClass::TcpConnect | DnsFailureClass::EndpointUnreachable
        ));
    }

    #[test]
    fn response_parser_follows_a_cname_chain_to_the_final_address() {
        let response = synthetic_cname_response(0x1234);
        assert_eq!(
            parse_response(&response, "example.com", 0x1234, QueryType::A).unwrap(),
            vec!["192.0.2.9".parse::<IpAddr>().unwrap()]
        );
    }

    fn synthetic_dns_response(id: u16, query_type: QueryType, address: &[u8]) -> Vec<u8> {
        let query = build_query("example.com", query_type, id).unwrap();
        let question_end = parse_query_name(&query, 12).unwrap().1 + 4;
        let mut response = query[..question_end].to_vec();
        response[2] = 0x81;
        response[3] = 0x80;
        response[6] = 0;
        response[7] = 1;
        response.extend_from_slice(&[0xc0, 0x0c]);
        response.extend_from_slice(&(query_type.as_u16()).to_be_bytes());
        response.extend_from_slice(&[0, 1, 0, 0, 0, 60]);
        response.extend_from_slice(&(address.len() as u16).to_be_bytes());
        response.extend_from_slice(address);
        response
    }

    fn synthetic_cname_response(id: u16) -> Vec<u8> {
        let query = build_query("example.com", QueryType::A, id).unwrap();
        let question_end = parse_query_name(&query, 12).unwrap().1 + 4;
        let mut response = query[..question_end].to_vec();
        response[2] = 0x81;
        response[3] = 0x80;
        response[6] = 0;
        response[7] = 2;

        // example.com -> alias.example.com
        response.extend_from_slice(&[0xc0, 0x0c]);
        response.extend_from_slice(&[0, 5, 0, 1, 0, 0, 0, 60]);
        let cname = [
            5, b'a', b'l', b'i', b'a', b's', 7, b'e', b'x', b'a', b'm', b'p', b'l', b'e', 3, b'c',
            b'o', b'm', 0,
        ];
        response.extend_from_slice(&(cname.len() as u16).to_be_bytes());
        response.extend_from_slice(&cname);

        // alias.example.com -> 192.0.2.9
        response.extend_from_slice(&cname);
        response.extend_from_slice(&[0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 9]);
        response
    }

    fn parse_query_type(query: &[u8]) -> Option<QueryType> {
        let (_, cursor) = parse_query_name(query, 12).ok()?;
        match u16::from_be_bytes([*query.get(cursor)?, *query.get(cursor + 1)?]) {
            1 => Some(QueryType::A),
            28 => Some(QueryType::AAAA),
            _ => None,
        }
    }

    fn synthetic_response_from_query(query: &[u8], query_type: QueryType) -> Vec<u8> {
        let question_end = parse_query_name(query, 12).unwrap().1 + 4;
        let mut response = query[..question_end].to_vec();
        response[2] = 0x81;
        response[3] = 0x80;
        response[6] = 0;
        response[7] = 1;
        response.extend_from_slice(&[0xc0, 0x0c]);
        response.extend_from_slice(&query_type.as_u16().to_be_bytes());
        response.extend_from_slice(&[0, 1, 0, 0, 0, 60]);
        match query_type {
            QueryType::A => {
                response.extend_from_slice(&[0, 4, 192, 0, 2, 9]);
            }
            QueryType::AAAA => {
                response.extend_from_slice(&[
                    0, 16, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9,
                ]);
            }
        }
        response
    }
}
