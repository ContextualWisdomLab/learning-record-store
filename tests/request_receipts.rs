use learning_record_store::{
    IngestionError, IngestionStatus, StatementCandidate, StatementKernel, TenantKey, XapiVersion,
};

fn candidate(
    tenant: &TenantKey,
    statement_key: &str,
    version: XapiVersion,
) -> StatementCandidate {
    StatementCandidate::new(
        tenant.clone(),
        statement_key,
        version,
        format!(r#"{{"id":"{statement_key}"}}"#).into_bytes(),
        format!("comparison:{statement_key}").into_bytes(),
    )
    .expect("valid statement candidate")
}

#[test]
fn one_request_receipt_can_own_multiple_indexed_statement_occurrences() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    let raw_request = br#"[{"id":"statement-a"},{"id":"statement-b"}]"#.to_vec();
    let receipt_number = kernel
        .begin_request(tenant.clone(), XapiVersion::V2_0, raw_request.clone())
        .expect("request receipt accepted");

    let first = kernel
        .ingest_at_receipt(
            receipt_number,
            0,
            candidate(&tenant, "statement-a", XapiVersion::V2_0),
        )
        .expect("first batch item accepted");
    let second = kernel
        .ingest_at_receipt(
            receipt_number,
            1,
            candidate(&tenant, "statement-b", XapiVersion::V2_0),
        )
        .expect("second batch item accepted");

    assert_eq!(first.status(), IngestionStatus::Accepted);
    assert_eq!(second.status(), IngestionStatus::Accepted);
    assert_eq!(kernel.receipts().len(), 1);
    assert_eq!(kernel.receipts()[0].raw_request_bytes(), raw_request);
    assert_eq!(kernel.occurrences().len(), 2);
    assert_eq!(kernel.occurrences()[0].receipt_number(), receipt_number);
    assert_eq!(kernel.occurrences()[0].request_statement_index(), 0);
    assert_eq!(kernel.occurrences()[1].receipt_number(), receipt_number);
    assert_eq!(kernel.occurrences()[1].request_statement_index(), 1);
}

#[test]
fn receipt_context_mismatch_fails_before_canonical_state_changes() {
    let mut kernel = StatementKernel::default();
    let alpha = TenantKey::new("tenant-alpha").expect("alpha tenant");
    let beta = TenantKey::new("tenant-beta").expect("beta tenant");
    let receipt_number = kernel
        .begin_request(alpha, XapiVersion::V2_0, b"request".to_vec())
        .expect("request receipt accepted");

    let tenant_error = kernel
        .ingest_at_receipt(
            receipt_number,
            0,
            candidate(&beta, "statement-beta", XapiVersion::V2_0),
        )
        .expect_err("cross-tenant receipt use rejected");
    assert!(matches!(
        tenant_error,
        IngestionError::ReceiptContextMismatch { .. }
    ));

    let version_error = kernel
        .ingest_at_receipt(
            receipt_number,
            0,
            candidate(&TenantKey::new("tenant-alpha").unwrap(), "statement-alpha", XapiVersion::V1_0_3),
        )
        .expect_err("cross-version receipt use rejected");
    assert!(matches!(
        version_error,
        IngestionError::ReceiptContextMismatch { .. }
    ));
    assert_eq!(kernel.statement_count(), 0);
    assert!(kernel.occurrences().is_empty());
}

#[test]
fn one_request_index_cannot_be_reused() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    let receipt_number = kernel
        .begin_request(tenant.clone(), XapiVersion::V2_0, b"request".to_vec())
        .expect("request receipt accepted");
    kernel
        .ingest_at_receipt(
            receipt_number,
            0,
            candidate(&tenant, "statement-a", XapiVersion::V2_0),
        )
        .expect("first item accepted");

    let error = kernel
        .ingest_at_receipt(
            receipt_number,
            0,
            candidate(&tenant, "statement-b", XapiVersion::V2_0),
        )
        .expect_err("receipt index is immutable");
    assert!(matches!(
        error,
        IngestionError::OccurrenceAlreadyRecorded { .. }
    ));
    assert_eq!(kernel.statement_count(), 1);
    assert_eq!(kernel.occurrences().len(), 1);
}

#[test]
fn unknown_receipt_fails_closed() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    let error = kernel
        .ingest_at_receipt(
            42,
            0,
            candidate(&tenant, "statement-a", XapiVersion::V2_0),
        )
        .expect_err("unknown receipt rejected");
    assert_eq!(
        error,
        IngestionError::ReceiptNotFound { receipt_number: 42 }
    );
}
