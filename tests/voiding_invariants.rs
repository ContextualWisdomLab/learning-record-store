//! Integration tests for non-destructive Statement voiding relations.

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

fn voiding_candidate(statement_key: &str, voided_statement_key: &str) -> StatementCandidate {
    StatementCandidate::new_voiding(
        TenantKey::new("tenant-alpha").expect("tenant key"),
        statement_key,
        XapiVersion::V2_0,
        format!(
            r#"{{"id":"{statement_key}","verb":{{"id":"http://adlnet.gov/expapi/verbs/voided"}},"object":{{"objectType":"StatementRef","id":"{voided_statement_key}"}}}}"#
        )
        .into_bytes(),
        format!("comparison:{statement_key}:{voided_statement_key}").into_bytes(),
        voided_statement_key,
    )
    .expect("validated voiding candidate")
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
        &error,
        IngestionError::InvalidVoidingRelation { .. }
    ));
    assert_eq!(
        error.to_string(),
        "invalid voiding relation: statement-voiding cannot void statement-voiding"
    );
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
        &error,
        IngestionError::VoidingTargetConflict { .. }
    ));
    assert_eq!(
        error.to_string(),
        "voiding target conflict for statement-voiding: existing target statement-target-a, attempted target statement-target-b"
    );
    let relations = kernel.voiding_relations();
    assert_eq!(relations.len(), 1);
    assert_eq!(relations[0].voiding_statement_key(), "statement-voiding");
    assert_eq!(relations[0].voided_statement_key(), "statement-target-a");
}

#[test]
fn a_voiding_statement_cannot_become_another_voiding_target() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    seed(&mut kernel, "statement-voiding-a");
    seed(&mut kernel, "statement-target-b");
    seed(&mut kernel, "statement-voiding-c");

    kernel
        .record_voiding(&tenant, "statement-voiding-a", "statement-target-b")
        .expect("first voiding relation accepted");

    let error = kernel
        .record_voiding(&tenant, "statement-voiding-c", "statement-voiding-a")
        .expect_err("a voiding Statement cannot itself be voided");

    assert!(matches!(
        &error,
        IngestionError::InvalidVoidingRelation { .. }
    ));
    assert_eq!(kernel.voiding_relations().len(), 1);
}


#[test]
fn ordinary_statement_cannot_authorize_a_voiding_relation() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    seed(&mut kernel, "statement-ordinary");
    seed(&mut kernel, "statement-target");

    let error = kernel
        .record_voiding_statement(&tenant, "statement-ordinary")
        .expect_err("ordinary Statement content cannot authorize voiding");

    assert_eq!(
        error,
        IngestionError::StatementIsNotVoiding {
            statement_key: "statement-ordinary".to_owned(),
        }
    );
    assert!(kernel.voiding_relations().is_empty());
}

#[test]
fn stored_voiding_target_is_the_only_authoritative_relation_target() {
    let mut kernel = StatementKernel::default();
    let tenant = TenantKey::new("tenant-alpha").expect("tenant key");
    seed(&mut kernel, "statement-target");
    kernel
        .ingest(voiding_candidate("statement-voiding", "statement-target"))
        .expect("validated voiding Statement accepted");

    kernel
        .record_voiding_statement(&tenant, "statement-voiding")
        .expect("stored Statement semantics authorize the relation");

    let relations = kernel.voiding_relations();
    assert_eq!(relations.len(), 1);
    assert_eq!(relations[0].voiding_statement_key(), "statement-voiding");
    assert_eq!(relations[0].voided_statement_key(), "statement-target");
}

#[test]
fn forged_voiding_semantics_cannot_reclassify_an_ordinary_statement() {
    let mut kernel = StatementKernel::default();
    seed(&mut kernel, "statement-source");
    seed(&mut kernel, "statement-target");

    let error = kernel
        .ingest(voiding_candidate("statement-source", "statement-target"))
        .expect_err("immutable ordinary Statement cannot be replayed as voiding");

    assert!(matches!(error, IngestionError::StatementConflict { .. }));
    assert!(kernel.voiding_relations().is_empty());
}
