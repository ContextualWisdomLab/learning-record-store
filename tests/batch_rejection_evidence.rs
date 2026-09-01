use learning_record_store::{
    IngestionError, IngestionStatus, StatementCandidate, StatementKernel, TenantKey, XapiVersion,
};

fn candidate(
    tenant: &str,
    statement: &str,
    version: XapiVersion,
    raw: &str,
    comparison: &[u8],
) -> StatementCandidate {
    StatementCandidate::new(
        TenantKey::new(tenant).expect("tenant key"),
        statement,
        version,
        raw.as_bytes().to_vec(),
        comparison.to_vec(),
    )
    .expect("valid statement candidate")
}

#[test]
fn conflicting_batch_records_every_submitted_item_without_partial_acceptance() {
    let mut kernel = StatementKernel::default();
    kernel
        .ingest(candidate(
            "tenant-alpha",
            "statement-existing",
            XapiVersion::V2_0,
            r#"{"id":"statement-existing","verb":"original"}"#,
            b"comparison-original",
        ))
        .expect("seed statement");
    let baseline_statement_count = kernel.statement_count();
    let baseline_occurrence_count = kernel.occurrences().len();

    let error = kernel
        .ingest_batch(
            TenantKey::new("tenant-alpha").unwrap(),
            XapiVersion::V2_0,
            br#"[{"id":"statement-new-a"},{"id":"statement-existing"},{"id":"statement-new-b"}]"#.to_vec(),
            vec![
                candidate(
                    "tenant-alpha",
                    "statement-new-a",
                    XapiVersion::V2_0,
                    r#"{"id":"statement-new-a"}"#,
                    b"comparison-new-a",
                ),
                candidate(
                    "tenant-alpha",
                    "statement-existing",
                    XapiVersion::V2_0,
                    r#"{"id":"statement-existing","verb":"conflict"}"#,
                    b"comparison-conflict",
                ),
                candidate(
                    "tenant-alpha",
                    "statement-new-b",
                    XapiVersion::V2_0,
                    r#"{"id":"statement-new-b"}"#,
                    b"comparison-new-b",
                ),
            ],
        )
        .expect_err("one conflicting item rejects the whole batch");

    assert!(matches!(error, IngestionError::StatementConflict { .. }));
    assert_eq!(kernel.statement_count(), baseline_statement_count);
    assert_eq!(kernel.receipts().len(), 2);

    let batch_occurrences = &kernel.occurrences()[baseline_occurrence_count..];
    assert_eq!(batch_occurrences.len(), 3);
    assert_eq!(
        batch_occurrences
            .iter()
            .map(|occurrence| occurrence.request_statement_index())
            .collect::<Vec<_>>(),
        vec![0, 1, 2]
    );
    assert_eq!(batch_occurrences[0].status(), IngestionStatus::BatchRejected);
    assert_eq!(batch_occurrences[1].status(), IngestionStatus::Conflict);
    assert_eq!(batch_occurrences[2].status(), IngestionStatus::BatchRejected);
    assert!(batch_occurrences
        .iter()
        .all(|occurrence| occurrence.receipt_number() == batch_occurrences[0].receipt_number()));
}

#[test]
fn duplicate_identity_is_detected_before_stored_conflict_comparison() {
    let mut kernel = StatementKernel::default();
    kernel
        .ingest(candidate(
            "tenant-alpha",
            "statement-duplicate",
            XapiVersion::V2_0,
            r#"{"id":"statement-duplicate","verb":"stored"}"#,
            b"comparison-stored",
        ))
        .expect("seed statement");
    let baseline_statement_count = kernel.statement_count();
    let baseline_occurrence_count = kernel.occurrences().len();

    let error = kernel
        .ingest_batch(
            TenantKey::new("tenant-alpha").unwrap(),
            XapiVersion::V2_0,
            br#"[{"id":"statement-duplicate"},{"id":"statement-duplicate"}]"#.to_vec(),
            vec![
                candidate(
                    "tenant-alpha",
                    "statement-duplicate",
                    XapiVersion::V2_0,
                    r#"{"id":"statement-duplicate","verb":"conflict-a"}"#,
                    b"comparison-conflict-a",
                ),
                candidate(
                    "tenant-alpha",
                    "statement-duplicate",
                    XapiVersion::V2_0,
                    r#"{"id":"statement-duplicate","verb":"conflict-b"}"#,
                    b"comparison-conflict-b",
                ),
            ],
        )
        .expect_err("duplicate request identity rejects before stored comparison");

    assert!(matches!(
        error,
        IngestionError::DuplicateStatementInRequest { .. }
    ));
    assert_eq!(kernel.statement_count(), baseline_statement_count);
    let batch_occurrences = &kernel.occurrences()[baseline_occurrence_count..];
    assert_eq!(batch_occurrences.len(), 2);
    assert!(batch_occurrences
        .iter()
        .all(|occurrence| occurrence.status() == IngestionStatus::BatchRejected));
}

#[test]
fn context_mismatch_records_every_item_as_batch_rejected() {
    let mut kernel = StatementKernel::default();

    let error = kernel
        .ingest_batch(
            TenantKey::new("tenant-alpha").unwrap(),
            XapiVersion::V2_0,
            br#"[{"id":"statement-alpha"},{"id":"statement-beta"}]"#.to_vec(),
            vec![
                candidate(
                    "tenant-alpha",
                    "statement-alpha",
                    XapiVersion::V2_0,
                    r#"{"id":"statement-alpha"}"#,
                    b"comparison-alpha",
                ),
                candidate(
                    "tenant-beta",
                    "statement-beta",
                    XapiVersion::V2_0,
                    r#"{"id":"statement-beta"}"#,
                    b"comparison-beta",
                ),
            ],
        )
        .expect_err("cross-context item rejects the whole request");

    assert!(matches!(error, IngestionError::ReceiptContextMismatch { .. }));
    assert_eq!(kernel.statement_count(), 0);
    assert_eq!(kernel.receipts().len(), 1);
    assert_eq!(kernel.occurrences().len(), 2);
    assert!(kernel
        .occurrences()
        .iter()
        .all(|occurrence| occurrence.status() == IngestionStatus::BatchRejected));
    assert!(kernel
        .occurrences()
        .iter()
        .all(|occurrence| occurrence.tenant_key().as_str() == "tenant-alpha"));
}
