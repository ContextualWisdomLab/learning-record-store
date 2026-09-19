//! Contract tests for parsing the xAPI request-version header.

use learning_record_store::{ReceivedXapiVersion, XapiVersion};

#[test]
fn accepted_headers_preserve_wire_value_and_select_one_surface() {
    for (wire_value, surface, statement_label, comparison_version) in [
        (
            "2.0",
            XapiVersion::V2_0,
            "2.0.0",
            "xapi-2.0-statement-comparison/v1",
        ),
        (
            "2.0.0",
            XapiVersion::V2_0,
            "2.0.0",
            "xapi-2.0-statement-comparison/v1",
        ),
        (
            "1.0",
            XapiVersion::V1_0_3,
            "1.0.0",
            "xapi-1.0.3-statement-comparison/v1",
        ),
        (
            "1.0.0",
            XapiVersion::V1_0_3,
            "1.0.0",
            "xapi-1.0.3-statement-comparison/v1",
        ),
        (
            "1.0.12",
            XapiVersion::V1_0_3,
            "1.0.0",
            "xapi-1.0.3-statement-comparison/v1",
        ),
    ] {
        let parsed = ReceivedXapiVersion::parse(wire_value).expect("supported header");

        assert_eq!(parsed.received_label(), wire_value);
        assert_eq!(parsed.protocol_surface(), surface);
        assert_eq!(parsed.canonical_statement_label(), statement_label);
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
