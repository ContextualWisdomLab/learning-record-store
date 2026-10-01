//! Contract tests for lossless adaptation to the internal PostgreSQL batch writer.

use learning_record_store::{
    IngestionError, PostgresStatementBatchParameters, ReceivedXapiVersion, StatementCandidate,
    TenantKey, XapiVersion,
};

fn candidate(
    tenant: &TenantKey,
    statement_key: &str,
    version: XapiVersion,
    raw: &[u8],
    comparison: &[u8],
) -> StatementCandidate {
    StatementCandidate::new(
        tenant.clone(),
        statement_key,
        version,
        raw.to_vec(),
        comparison.to_vec(),
    )
    .expect("fixture candidate must be valid")
}

#[test]
fn durable_batch_parameters_preserve_wire_label_order_duplicates_and_bytes() {
    let tenant = TenantKey::new("tenant-alpha").unwrap();
    let received_version = ReceivedXapiVersion::parse("1.0.12").unwrap();
    let candidates = vec![
        candidate(
            &tenant,
            "statement-repeat",
            XapiVersion::V1_0_3,
            br#"{"id":"statement-repeat","attempt":1}"#,
            b"comparison-one",
        ),
        candidate(
            &tenant,
            "statement-repeat",
            XapiVersion::V1_0_3,
            br#"{"id":"statement-repeat","attempt":2}"#,
            b"comparison-two",
        ),
    ];

    let parameters = PostgresStatementBatchParameters::from_received_batch(
        tenant,
        &received_version,
        br#"[{"id":"statement-repeat","attempt":1},{"id":"statement-repeat","attempt":2}]"#
            .to_vec(),
        candidates,
    )
    .unwrap();

    assert_eq!(parameters.tenant_key(), "tenant-alpha");
    assert_eq!(parameters.received_xapi_version(), "1.0.12");
    assert_eq!(
        parameters.raw_request_bytes(),
        br#"[{"id":"statement-repeat","attempt":1},{"id":"statement-repeat","attempt":2}]"#
    );
    assert_eq!(
        parameters.statement_keys(),
        ["statement-repeat", "statement-repeat"]
    );
    assert_eq!(
        parameters.statement_comparison_versions(),
        [
            "xapi-1.0.3-statement-comparison/v1",
            "xapi-1.0.3-statement-comparison/v1"
        ]
    );
    assert_eq!(
        parameters.comparison_bytes(),
        [b"comparison-one".as_slice(), b"comparison-two".as_slice()]
    );
    assert_eq!(
        parameters.raw_statement_bytes(),
        [
            br#"{"id":"statement-repeat","attempt":1}"#.as_slice(),
            br#"{"id":"statement-repeat","attempt":2}"#.as_slice()
        ]
    );
}

#[test]
fn durable_batch_parameters_reject_empty_request_and_empty_batch() {
    let tenant = TenantKey::new("tenant-alpha").unwrap();
    let received_version = ReceivedXapiVersion::parse("2.0").unwrap();

    let empty_request = PostgresStatementBatchParameters::from_received_batch(
        tenant.clone(),
        &received_version,
        Vec::new(),
        vec![candidate(
            &tenant,
            "statement-one",
            XapiVersion::V2_0,
            b"statement-one",
            b"comparison-one",
        )],
    );
    assert_eq!(
        empty_request,
        Err(IngestionError::InvalidEvidence {
            field: "raw_request_bytes"
        })
    );

    let empty_batch = PostgresStatementBatchParameters::from_received_batch(
        tenant,
        &received_version,
        b"[]".to_vec(),
        Vec::new(),
    );
    assert_eq!(
        empty_batch,
        Err(IngestionError::InvalidEvidence {
            field: "statement_batch_cardinality"
        })
    );
}

#[test]
fn durable_batch_parameters_reject_tenant_or_version_context_mismatch() {
    let tenant = TenantKey::new("tenant-alpha").unwrap();
    let other_tenant = TenantKey::new("tenant-beta").unwrap();
    let received_version = ReceivedXapiVersion::parse("2.0").unwrap();

    for mismatched_candidate in [
        candidate(
            &other_tenant,
            "statement-one",
            XapiVersion::V2_0,
            b"statement-one",
            b"comparison-one",
        ),
        candidate(
            &tenant,
            "statement-one",
            XapiVersion::V1_0_3,
            b"statement-one",
            b"comparison-one",
        ),
    ] {
        let result = PostgresStatementBatchParameters::from_received_batch(
            tenant.clone(),
            &received_version,
            b"[{}]".to_vec(),
            vec![mismatched_candidate],
        );
        assert_eq!(
            result,
            Err(IngestionError::InvalidEvidence {
                field: "statement_batch_context"
            })
        );
    }
}

#[test]
fn durable_batch_parameters_reject_unrepresentable_voiding_semantics() {
    let tenant = TenantKey::new("tenant-alpha").unwrap();
    let received_version = ReceivedXapiVersion::parse("2.0").unwrap();
    let voiding = StatementCandidate::new_voiding(
        tenant.clone(),
        "voiding-statement",
        XapiVersion::V2_0,
        b"voiding-statement".to_vec(),
        b"voiding-comparison".to_vec(),
        "voided-statement",
    )
    .unwrap();

    let result = PostgresStatementBatchParameters::from_received_batch(
        tenant,
        &received_version,
        b"[{}]".to_vec(),
        vec![voiding],
    );

    assert_eq!(
        result,
        Err(IngestionError::InvalidEvidence {
            field: "durable_batch_voiding_not_supported"
        })
    );
}
