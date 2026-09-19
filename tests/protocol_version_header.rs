//! Contract tests for parsing the xAPI request-version header.

use learning_record_store::{ReceivedXapiVersion, XapiVersion};

#[test]
fn accepted_headers_preserve_wire_value_and_select_one_surface() {
    for (wire_value, surface, statement_label, response_label, comparison_version) in [
        (
            "2.0",
            XapiVersion::V2_0,
            "2.0.0",
            "2.0.0",
            "xapi-2.0-statement-comparison/v1",
        ),
        (
            "2.0.0",
            XapiVersion::V2_0,
            "2.0.0",
            "2.0.0",
            "xapi-2.0-statement-comparison/v1",
        ),
        (
            "1.0",
            XapiVersion::V1_0_3,
            "1.0.0",
            "1.0.3",
            "xapi-1.0.3-statement-comparison/v1",
        ),
        (
            "1.0.0",
            XapiVersion::V1_0_3,
            "1.0.0",
            "1.0.3",
            "xapi-1.0.3-statement-comparison/v1",
        ),
        (
            "1.0.12",
            XapiVersion::V1_0_3,
            "1.0.0",
            "1.0.3",
            "xapi-1.0.3-statement-comparison/v1",
        ),
    ] {
        let parsed = ReceivedXapiVersion::parse(wire_value).expect("supported header");

        assert_eq!(parsed.received_label(), wire_value);
        assert_eq!(parsed.protocol_surface(), surface);
        assert_eq!(parsed.canonical_statement_label(), statement_label);
        assert_eq!(parsed.response_header_value(), response_label);
        assert_eq!(parsed.statement_comparison_version(), comparison_version);
    }
}

#[test]
fn unsupported_or_ambiguous_headers_fail_closed_without_normalization() {
    for wire_value in [
        "",
        " ",
        "2",
        "2.0.1",
        "02.0",
        "1",
        "1.0.",
        "1.0.03",
        "1.0.1a",
        "1.0.-1",
        "1.1.0",
        "0.9",
        " 2.0",
        "2.0 ",
        "2.0, 1.0.3",
    ] {
        let error = ReceivedXapiVersion::parse(wire_value)
            .expect_err("unsupported version header must fail closed");

        assert_eq!(error.received_label(), wire_value);
        assert_eq!(
            error.to_string(),
            format!("unsupported xAPI request version: {wire_value:?}")
        );
    }
}

#[test]
fn http_header_extraction_requires_one_utf8_value() {
    let accepted_values = [b"2.0".as_slice()];
    let accepted = ReceivedXapiVersion::from_header_values(&accepted_values)
        .expect("one supported HTTP header value");
    assert_eq!(accepted.received_label(), "2.0");

    assert_eq!(
        ReceivedXapiVersion::from_header_values(&[])
            .expect_err("missing version header must fail closed")
            .to_string(),
        "missing X-Experience-API-Version header"
    );

    let duplicate_values = [b"2.0".as_slice(), b"2.0.0".as_slice()];
    assert_eq!(
        ReceivedXapiVersion::from_header_values(&duplicate_values)
            .expect_err("multiple version headers must fail closed")
            .to_string(),
        "multiple X-Experience-API-Version header values: 2"
    );

    let invalid_utf8 = [&[0xff][..]];
    assert_eq!(
        ReceivedXapiVersion::from_header_values(&invalid_utf8)
            .expect_err("non-UTF-8 version header must fail closed")
            .to_string(),
        "non-UTF-8 X-Experience-API-Version header value"
    );

    let unsupported_value = [b"2.0.1".as_slice()];
    assert_eq!(
        ReceivedXapiVersion::from_header_values(&unsupported_value)
            .expect_err("unsupported version header must fail closed")
            .to_string(),
        "unsupported xAPI request version: \"2.0.1\""
    );
}
