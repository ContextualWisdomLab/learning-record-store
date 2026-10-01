//! Contract tests for parsing the xAPI request-version header.

use learning_record_store::{
    IngestionStatus, ReceivedXapiVersion, StatementCandidate, StatementKernel, TenantKey,
    XapiVersion, XAPI_VERSION_HEADER_NAME,
};

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

#[test]
fn response_header_contract_uses_latest_supported_surface_value() {
    assert_eq!(XAPI_VERSION_HEADER_NAME, "X-Experience-API-Version");

    for (request_value, expected_response_value) in [
        ("2.0", "2.0.0"),
        ("2.0.0", "2.0.0"),
        ("1.0", "1.0.3"),
        ("1.0.12", "1.0.3"),
    ] {
        let received_version =
            ReceivedXapiVersion::parse(request_value).expect("supported request version");

        assert_eq!(
            received_version.response_header(),
            ("X-Experience-API-Version", expected_response_value)
        );
    }
}

#[test]
fn receipt_preserves_exact_request_version_label() {
    let mut kernel = StatementKernel::default();
    let tenant_key = TenantKey::new("tenant-version-evidence").expect("valid tenant key");

    for (received_label, protocol_surface) in [
        ("2.0", XapiVersion::V2_0),
        ("2.0.0", XapiVersion::V2_0),
        ("1.0", XapiVersion::V1_0_3),
        ("1.0.12", XapiVersion::V1_0_3),
    ] {
        let received_version =
            ReceivedXapiVersion::parse(received_label).expect("supported request version");
        let receipt_number = kernel
            .begin_received_request(
                tenant_key.clone(),
                &received_version,
                format!("request:{received_label}").into_bytes(),
            )
            .expect("immutable request receipt");
        let receipt = kernel.receipts().last().expect("receipt must be retained");

        assert_eq!(receipt.receipt_number(), receipt_number);
        assert_eq!(receipt.received_xapi_label(), received_label);
        assert_eq!(receipt.received_xapi_version(), protocol_surface);
    }
}

#[test]
fn batch_receipt_preserves_exact_request_version_label() {
    let mut kernel = StatementKernel::default();
    let tenant_key = TenantKey::new("tenant-batch-version-evidence").expect("valid tenant key");
    let received_version = ReceivedXapiVersion::parse("1.0.12").expect("supported request version");
    let raw_request = br#"[{"id":"statement-a"},{"id":"statement-b"}]"#.to_vec();
    let candidates = ["statement-a", "statement-b"].map(|statement_key| {
        StatementCandidate::new(
            tenant_key.clone(),
            statement_key,
            XapiVersion::V1_0_3,
            format!(r#"{{"id":"{statement_key}"}}"#).into_bytes(),
            format!("comparison:{statement_key}").into_bytes(),
        )
        .expect("valid statement candidate")
    });

    let outcomes = kernel
        .ingest_received_batch(
            tenant_key,
            &received_version,
            raw_request.clone(),
            candidates.into(),
        )
        .expect("validated batch accepted atomically");

    assert_eq!(outcomes.len(), 2);
    assert!(outcomes
        .iter()
        .all(|outcome| outcome.status() == IngestionStatus::Accepted));
    assert_eq!(outcomes[0].receipt_number(), outcomes[1].receipt_number());
    assert_eq!(kernel.receipts().len(), 1);
    assert_eq!(kernel.receipts()[0].raw_request_bytes(), raw_request);
    assert_eq!(kernel.receipts()[0].received_xapi_label(), "1.0.12");
    assert_eq!(
        kernel.receipts()[0].received_xapi_version(),
        XapiVersion::V1_0_3
    );
}

#[test]
fn received_batch_rejects_empty_collection_before_receipt_creation() {
    let mut kernel = StatementKernel::default();
    let tenant_key = TenantKey::new("tenant-empty-batch").expect("valid tenant key");
    let received_version = ReceivedXapiVersion::parse("2.0").expect("supported request version");

    let error = kernel
        .ingest_received_batch(tenant_key, &received_version, b"[]".to_vec(), Vec::new())
        .expect_err("empty batch must fail closed");

    assert_eq!(error.to_string(), "invalid evidence: statement_batch");
    assert!(kernel.receipts().is_empty());
    assert!(kernel.occurrences().is_empty());
}

#[test]
fn received_batch_rejects_empty_request_evidence_before_state_change() {
    let mut kernel = StatementKernel::default();
    let tenant_key = TenantKey::new("tenant-empty-request").expect("valid tenant key");
    let received_version = ReceivedXapiVersion::parse("2.0").expect("supported request version");
    let candidate = StatementCandidate::new(
        tenant_key.clone(),
        "statement-empty-request",
        XapiVersion::V2_0,
        br#"{"id":"statement-empty-request"}"#.to_vec(),
        b"comparison:statement-empty-request".to_vec(),
    )
    .expect("valid statement candidate");

    let error = kernel
        .ingest_received_batch(tenant_key, &received_version, Vec::new(), vec![candidate])
        .expect_err("empty request evidence must fail closed");

    assert_eq!(error.to_string(), "invalid evidence: raw_request_bytes");
    assert!(kernel.receipts().is_empty());
    assert!(kernel.occurrences().is_empty());
    assert_eq!(kernel.statement_count(), 0);
}
