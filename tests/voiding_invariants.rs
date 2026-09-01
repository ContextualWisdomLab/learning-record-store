use learning_record_store::{
    IngestionError, StatementCandidate, StatementKernel, TenantKey, XapiVersion,
};

fn candidate(statement_key: &str) -> StatementCandidate {
    StatementCandidate::new(
        TenantKey::new("tenant-alpha").expect("tenant key"),
        statement_key,
        XapiVersion::V2_0,
        format!(r#"{{"id":"{statement_key}"}}"#).into_bytes(),
        format!("comparison:{statement_key}").into_bytes(),
    )
    .expect("valid statement candidate")
}

fn seed(kernel: &mut StatementKernel, statement_key: &str) {
    kernel
        .ingest(candidate(statement_key))
        .expect("seed statement accepted");
}

#[test]
fn self_voiding_is_rejected_before_persistence() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    seed(&mut kernel, "statement-voiding");

    let error = kernel
        .record_voiding(&tenant, "statement-voiding", "statement-voiding")
        .expect_err("a Statement cannot void itself");

    assert!(matches!(
        error,
        IngestionError::InvalidVoidingRelation { .. }
    ));
    assert!(kernel.voiding_relations().is_empty());
}

#[test]
fn one_voiding_statement_cannot_acquire_multiple_targets() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    seed(&mut kernel, "statement-voiding");
    seed(&mut kernel, "statement-target-a");
    seed(&mut kernel, "statement-target-b");

    kernel
        .record_voiding(&tenant, "statement-voiding", "statement-target-a")
        .expect("first voiding relation accepted");
    kernel
        .record_voiding(&tenant, "statement-voiding", "statement-target-a")
        .expect("same voiding relation is idempotent");

    let error = kernel
        .record_voiding(&tenant, "statement-voiding", "statement-target-b")
        .expect_err("immutable voiding Statement cannot change target");

    assert!(matches!(
        error,
        IngestionError::VoidingTargetConflict { .. }
    ));
    let relations = kernel.voiding_relations();
    assert_eq!(relations.len(), 1);
    assert_eq!(relations[0].voiding_statement_key(), "statement-voiding");
    assert_eq!(relations[0].voided_statement_key(), "statement-target-a");
}
