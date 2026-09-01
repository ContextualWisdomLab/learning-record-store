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
fn first_ingest_preserves_exact_source_evidence() {
    let mut kernel = StatementKernel::default();
    let raw = br#"{"id":"statement-001","actor":{"objectType":"Agent"}}"#;
    let outcome = kernel
        .ingest(candidate(
            "tenant-alpha",
            "statement-001",
            XapiVersion::V2_0,
            std::str::from_utf8(raw).expect("utf8"),
            b"xapi-2.0-comparison:statement-001",
        ))
        .expect("first ingest accepted");

    assert_eq!(outcome.status(), IngestionStatus::Accepted);
    assert_eq!(outcome.statement().raw_statement_bytes(), raw);
    assert_eq!(kernel.receipts().len(), 1);
    assert_eq!(kernel.receipts()[0].raw_request_bytes(), raw);
    assert_eq!(kernel.occurrences().len(), 1);
}

#[test]
fn equivalent_replay_reuses_canonical_statement_and_keeps_new_receipt() {
    let mut kernel = StatementKernel::default();
    let first = candidate(
        "tenant-alpha",
        "statement-001",
        XapiVersion::V2_0,
        r#"{"id":"statement-001","verb":"completed"}"#,
        b"comparison-equivalent",
    );
    let replay_raw = r#"{ "verb":"completed", "id":"statement-001" }"#;
    let replay = candidate(
        "tenant-alpha",
        "statement-001",
        XapiVersion::V2_0,
        replay_raw,
        b"comparison-equivalent",
    );

    let accepted = kernel.ingest(first).expect("first ingest accepted");
    let replayed = kernel.ingest(replay).expect("equivalent replay accepted");

    assert_eq!(replayed.status(), IngestionStatus::Replayed);
    assert_eq!(accepted.statement(), replayed.statement());
    assert_eq!(kernel.statement_count(), 1);
    assert_eq!(kernel.receipts().len(), 2);
    assert_eq!(kernel.receipts()[1].raw_request_bytes(), replay_raw.as_bytes());
    assert_eq!(kernel.occurrences().len(), 2);
}

#[test]
fn conflicting_replay_fails_closed_without_overwriting_canonical_evidence() {
    let mut kernel = StatementKernel::default();
    let original = candidate(
        "tenant-alpha",
        "statement-001",
        XapiVersion::V2_0,
        r#"{"id":"statement-001","verb":"completed"}"#,
        b"comparison-original",
    );
    let conflict_raw = r#"{"id":"statement-001","verb":"failed"}"#;
    let conflict = candidate(
        "tenant-alpha",
        "statement-001",
        XapiVersion::V2_0,
        conflict_raw,
        b"comparison-conflict",
    );

    kernel.ingest(original).expect("first ingest accepted");
    let error = kernel.ingest(conflict).expect_err("conflict must fail closed");

    assert!(matches!(error, IngestionError::StatementConflict { .. }));
    assert_eq!(kernel.statement_count(), 1);
    assert_eq!(kernel.receipts().len(), 2);
    assert_eq!(kernel.receipts()[1].raw_request_bytes(), conflict_raw.as_bytes());
    assert_eq!(kernel.occurrences().len(), 2);
    assert_eq!(
        kernel
            .statement(&TenantKey::new("tenant-alpha").unwrap(), "statement-001")
            .unwrap()
            .raw_statement_bytes(),
        br#"{"id":"statement-001","verb":"completed"}"#
    );
}

#[test]
fn received_protocol_version_mismatch_is_a_conflict_not_an_upgrade() {
    let mut kernel = StatementKernel::default();
    kernel
        .ingest(candidate(
            "tenant-alpha",
            "statement-001",
            XapiVersion::V1_0_3,
            r#"{"id":"statement-001"}"#,
            b"same-comparison",
        ))
        .expect("first ingest accepted");

    let error = kernel
        .ingest(candidate(
            "tenant-alpha",
            "statement-001",
            XapiVersion::V2_0,
            r#"{"id":"statement-001"}"#,
            b"same-comparison",
        ))
        .expect_err("cross-version replay must fail closed");

    assert!(matches!(error, IngestionError::StatementConflict { .. }));
}

#[test]
fn tenant_scope_is_part_of_canonical_identity() {
    let mut kernel = StatementKernel::default();
    kernel
        .ingest(candidate(
            "tenant-alpha",
            "statement-001",
            XapiVersion::V2_0,
            r#"{"id":"statement-001","tenant":"alpha"}"#,
            b"alpha",
        ))
        .unwrap();
    kernel
        .ingest(candidate(
            "tenant-beta",
            "statement-001",
            XapiVersion::V2_0,
            r#"{"id":"statement-001","tenant":"beta"}"#,
            b"beta",
        ))
        .unwrap();

    let alpha = TenantKey::new("tenant-alpha").unwrap();
    let beta = TenantKey::new("tenant-beta").unwrap();
    assert_ne!(
        kernel.statement(&alpha, "statement-001").unwrap(),
        kernel.statement(&beta, "statement-001").unwrap()
    );
    assert_eq!(kernel.statement_count(), 2);
}

#[test]
fn voiding_relation_never_deletes_original_statement() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").unwrap();
    kernel
        .ingest(candidate(
            "tenant-alpha",
            "statement-original",
            XapiVersion::V2_0,
            r#"{"id":"statement-original"}"#,
            b"original",
        ))
        .unwrap();
    kernel
        .ingest(candidate(
            "tenant-alpha",
            "statement-voiding",
            XapiVersion::V2_0,
            r#"{"id":"statement-voiding"}"#,
            b"voiding",
        ))
        .unwrap();

    kernel
        .record_voiding(&tenant, "statement-voiding", "statement-original")
        .expect("valid voiding relation");

    assert!(kernel.statement(&tenant, "statement-original").is_some());
    assert_eq!(kernel.voiding_relations().len(), 1);
}

#[test]
fn invalid_identity_and_missing_void_targets_fail_closed() {
    assert!(TenantKey::new("   ").is_err());
    assert!(StatementCandidate::new(
        TenantKey::new("tenant-alpha").unwrap(),
        " ",
        XapiVersion::V2_0,
        vec![b'{', b'}'],
        b"comparison".to_vec(),
    )
    .is_err());

    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").unwrap();
    let error = kernel
        .record_voiding(&tenant, "missing-voiding", "missing-target")
        .expect_err("missing statements cannot be linked");
    assert!(matches!(error, IngestionError::StatementNotFound { .. }));
}
