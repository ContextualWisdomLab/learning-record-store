use learning_record_store::{
    IngestionError, IngestionStatus, StatementCandidate, StatementKernel, TenantKey, XapiVersion,
};

fn candidate(
    tenant: &TenantKey,
    statement_key: &str,
    version: XapiVersion,
) -> StatementCandidate {
    candidate_with_comparison(
        tenant,
        statement_key,
        version,
        format!("comparison:{statement_key}"),
    )
}

fn candidate_with_comparison(
    tenant: &TenantKey,
    statement_key: &str,
    version: XapiVersion,
    comparison: impl Into<String>,
) -> StatementCandidate {
    StatementCandidate::new(
        tenant.clone(),
        statement_key,
        version,
        format!(r#"{{"id":"{statement_key}"}}"#).into_bytes(),
        comparison.into().into_bytes(),
    )
    .expect("valid statement candidate")
}

#[test]
fn one_request_receipt_can_own_multiple_indexed_statement_occurrences() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    let raw_request = br#"[{"id":"statement-a"},{"id":"statement-b"}]"#.to_vec();
    let outcomes = kernel
        .ingest_batch(
            tenant.clone(),
            XapiVersion::V2_0,
            raw_request.clone(),
            vec![
                candidate(&tenant, "statement-a", XapiVersion::V2_0),
                candidate(&tenant, "statement-b", XapiVersion::V2_0),
            ],
        )
        .expect("validated batch accepted atomically");

    assert_eq!(outcomes.len(), 2);
    assert_eq!(outcomes[0].status(), IngestionStatus::Accepted);
    assert_eq!(outcomes[1].status(), IngestionStatus::Accepted);
    assert_eq!(outcomes[0].receipt_number(), outcomes[1].receipt_number());
    assert_eq!(kernel.receipts().len(), 1);
    assert_eq!(kernel.receipts()[0].raw_request_bytes(), raw_request);
    assert_eq!(kernel.occurrences().len(), 2);
    assert_eq!(kernel.occurrences()[0].request_statement_index(), 0);
    assert_eq!(kernel.occurrences()[1].request_statement_index(), 1);
}

#[test]
fn batch_can_mix_exact_replay_and_new_statement_atomically() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    kernel
        .ingest(candidate(&tenant, "statement-existing", XapiVersion::V2_0))
        .expect("seed statement accepted");

    let outcomes = kernel
        .ingest_batch(
            tenant.clone(),
            XapiVersion::V2_0,
            br#"[{"id":"statement-existing"},{"id":"statement-new"}]"#.to_vec(),
            vec![
                candidate(&tenant, "statement-existing", XapiVersion::V2_0),
                candidate(&tenant, "statement-new", XapiVersion::V2_0),
            ],
        )
        .expect("replay plus new statement accepted as one batch");

    assert_eq!(outcomes.len(), 2);
    assert_eq!(outcomes[0].status(), IngestionStatus::Replayed);
    assert_eq!(outcomes[1].status(), IngestionStatus::Accepted);
    assert_eq!(outcomes[0].receipt_number(), outcomes[1].receipt_number());
    assert_eq!(kernel.statement_count(), 2);
    assert_eq!(kernel.receipts().len(), 2);
    assert_eq!(kernel.occurrences().len(), 3);
}

#[test]
fn batch_conflict_retains_receipt_without_partial_canonical_acceptance() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    kernel
        .ingest(candidate_with_comparison(
            &tenant,
            "statement-existing",
            XapiVersion::V2_0,
            "comparison:original",
        ))
        .expect("seed statement accepted");
    let statement_count_before_batch = kernel.statement_count();
    let occurrence_count_before_batch = kernel.occurrences().len();

    let error = kernel
        .ingest_batch(
            tenant.clone(),
            XapiVersion::V2_0,
            br#"[{"id":"statement-new"},{"id":"statement-existing"}]"#.to_vec(),
            vec![
                candidate(&tenant, "statement-new", XapiVersion::V2_0),
                candidate_with_comparison(
                    &tenant,
                    "statement-existing",
                    XapiVersion::V2_0,
                    "comparison:conflicting",
                ),
            ],
        )
        .expect_err("a later conflict rejects canonical writes for the whole batch");

    let receipt_number = match error {
        IngestionError::StatementConflict {
            receipt_number,
            statement_key,
        } => {
            assert_eq!(statement_key, "statement-existing");
            receipt_number
        }
        other => panic!("unexpected error: {other}"),
    };
    assert_eq!(kernel.statement_count(), statement_count_before_batch);
    assert_eq!(kernel.receipts().len(), 2);
    assert_eq!(kernel.receipts()[1].receipt_number(), receipt_number);
    assert_eq!(kernel.occurrences().len(), occurrence_count_before_batch + 1);
    let rejected_occurrence = kernel.occurrences().last().expect("conflict occurrence");
    assert_eq!(rejected_occurrence.receipt_number(), receipt_number);
    assert_eq!(rejected_occurrence.request_statement_index(), 1);
    assert_eq!(rejected_occurrence.status(), IngestionStatus::Conflict);
}

#[test]
fn duplicate_statement_ids_reject_batch_before_canonical_changes() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");

    let error = kernel
        .ingest_batch(
            tenant.clone(),
            XapiVersion::V2_0,
            br#"[{"id":"statement-a"},{"id":"statement-a"}]"#.to_vec(),
            vec![
                candidate(&tenant, "statement-a", XapiVersion::V2_0),
                candidate(&tenant, "statement-a", XapiVersion::V2_0),
            ],
        )
        .expect_err("duplicate Statement IDs fail closed");

    assert!(matches!(
        &error,
        IngestionError::DuplicateStatementInRequest { .. }
    ));
    let receipt_number = kernel.receipts()[0].receipt_number();
    assert_eq!(
        error.to_string(),
        format!("duplicate statement statement-a in request receipt {receipt_number}")
    );
    assert_eq!(kernel.statement_count(), 0);
    assert_eq!(kernel.receipts().len(), 1);
    assert!(kernel.occurrences().is_empty());
}

#[test]
fn empty_batch_fails_before_creating_request_receipt() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");

    let error = kernel
        .ingest_batch(
            tenant,
            XapiVersion::V2_0,
            b"[]".to_vec(),
            Vec::new(),
        )
        .expect_err("empty batch rejected");

    assert_eq!(error.to_string(), "invalid evidence: statement_batch");
    assert!(kernel.receipts().is_empty());
    assert_eq!(kernel.statement_count(), 0);
}

#[test]
fn batch_context_mismatch_retains_request_but_changes_no_statement_state() {
    let mut kernel = StatementKernel::default();
    let alpha = TenantKey::new("tenant-alpha").expect("alpha tenant");
    let beta = TenantKey::new("tenant-beta").expect("beta tenant");

    let tenant_error = kernel
        .ingest_batch(
            alpha.clone(),
            XapiVersion::V2_0,
            br#"[{"id":"statement-beta"}]"#.to_vec(),
            vec![candidate(&beta, "statement-beta", XapiVersion::V2_0)],
        )
        .expect_err("batch tenant mismatch rejected");
    assert!(matches!(
        &tenant_error,
        IngestionError::ReceiptContextMismatch { .. }
    ));
    assert_eq!(kernel.statement_count(), 0);
    assert_eq!(kernel.receipts().len(), 1);
    assert!(kernel.occurrences().is_empty());

    let version_error = kernel
        .ingest_batch(
            alpha.clone(),
            XapiVersion::V2_0,
            br#"[{"id":"statement-alpha"}]"#.to_vec(),
            vec![candidate(
                &alpha,
                "statement-alpha",
                XapiVersion::V1_0_3,
            )],
        )
        .expect_err("batch version mismatch rejected");
    assert!(matches!(
        &version_error,
        IngestionError::ReceiptContextMismatch { .. }
    ));
    assert_eq!(kernel.statement_count(), 0);
    assert_eq!(kernel.receipts().len(), 2);
    assert!(kernel.occurrences().is_empty());
}

#[test]
fn empty_request_receipt_evidence_is_rejected() {
    let mut kernel = StatementKernel::default();
    let error = kernel
        .begin_request(
            TenantKey::new("tenant-alpha").expect("tenant key"),
            XapiVersion::V2_0,
            Vec::new(),
        )
        .expect_err("empty request evidence rejected");
    assert_eq!(error.to_string(), "invalid evidence: raw_request_bytes");
    assert!(kernel.receipts().is_empty());
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
        &tenant_error,
        IngestionError::ReceiptContextMismatch { .. }
    ));
    assert_eq!(
        tenant_error.to_string(),
        format!("request receipt context mismatch: {receipt_number}")
    );

    let version_error = kernel
        .ingest_at_receipt(
            receipt_number,
            0,
            candidate(
                &TenantKey::new("tenant-alpha").unwrap(),
                "statement-alpha",
                XapiVersion::V1_0_3,
            ),
        )
        .expect_err("cross-version receipt use rejected");
    assert!(matches!(
        &version_error,
        IngestionError::ReceiptContextMismatch { .. }
    ));
    assert_eq!(
        version_error.to_string(),
        format!("request receipt context mismatch: {receipt_number}")
    );
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
        &error,
        IngestionError::OccurrenceAlreadyRecorded { .. }
    ));
    assert_eq!(
        error.to_string(),
        format!("request occurrence already recorded: receipt {receipt_number}, index 0")
    );
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
    assert_eq!(error.to_string(), "request receipt not found: 42");
}
