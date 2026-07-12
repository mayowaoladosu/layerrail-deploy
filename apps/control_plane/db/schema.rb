# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_12_202000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "aliases", id: :uuid, default: nil, force: :cascade do |t|
    t.string "alias_type", limit: 32, null: false
    t.datetime "created_at", null: false
    t.uuid "current_revision_id", null: false
    t.string "current_revision_status", limit: 32, null: false
    t.uuid "environment_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "name", limit: 255, null: false
    t.uuid "organization_id", null: false
    t.uuid "previous_revision_id"
    t.string "previous_revision_status", limit: 32
    t.uuid "project_id", null: false
    t.uuid "service_id", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "project_id", "environment_id"], name: "idx_on_organization_id_project_id_environment_id_0ad74266ad"
    t.index ["service_id", "alias_type", "name"], name: "index_aliases_on_service_id_and_alias_type_and_name", unique: true
    t.check_constraint "alias_type::text = 'environment'::text OR alias_type::text = 'branch'::text", name: "aliases_type_allowed"
    t.check_constraint "current_revision_status::text = 'ready'::text", name: "aliases_current_revision_ready"
    t.check_constraint "name::text = btrim(name::text) AND name::text <> ''::text", name: "aliases_name_normalized"
    t.check_constraint "previous_revision_id IS NULL AND previous_revision_status IS NULL OR previous_revision_id IS NOT NULL AND previous_revision_status::text = 'ready'::text", name: "aliases_previous_revision_ready"
    t.check_constraint "previous_revision_id IS NULL OR previous_revision_id <> current_revision_id", name: "aliases_revisions_distinct"
  end

  create_table "authentication_request_attempts", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_digest", limit: 64, null: false
    t.string "ip_digest", limit: 64
    t.datetime "updated_at", null: false
    t.index ["email_digest", "created_at"], name: "idx_on_email_digest_created_at_7255cb1346"
    t.index ["ip_digest", "created_at"], name: "idx_on_ip_digest_created_at_97d19ba034"
    t.check_constraint "email_digest::text ~ '^[0-9a-f]{64}$'::text", name: "authentication_request_attempts_email_digest_format"
    t.check_constraint "ip_digest IS NULL OR ip_digest::text ~ '^[0-9a-f]{64}$'::text", name: "authentication_request_attempts_ip_digest_format"
  end

  create_table "builds", id: :uuid, default: nil, force: :cascade do |t|
    t.string "artifact_digest", limit: 71
    t.integer "attempt", null: false
    t.datetime "created_at", null: false
    t.uuid "deployment_id", null: false
    t.jsonb "evidence", default: {}, null: false
    t.datetime "finished_at"
    t.string "idempotency_key", limit: 255, null: false
    t.integer "lock_version", default: 0, null: false
    t.uuid "organization_id", null: false
    t.datetime "started_at", null: false
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["deployment_id", "attempt"], name: "index_builds_on_deployment_id_and_attempt", unique: true
    t.index ["deployment_id", "idempotency_key"], name: "index_builds_on_deployment_id_and_idempotency_key", unique: true
    t.index ["deployment_id"], name: "index_builds_on_deployment_id"
    t.index ["id", "deployment_id", "organization_id", "artifact_digest"], name: "index_builds_on_revision_identity", unique: true
    t.index ["organization_id", "status", "created_at"], name: "index_builds_on_organization_id_and_status_and_created_at"
    t.index ["organization_id"], name: "index_builds_on_organization_id"
    t.check_constraint "artifact_digest IS NULL OR artifact_digest::text ~ '^sha256:[0-9a-f]{64}$'::text", name: "builds_artifact_digest_format"
    t.check_constraint "attempt > 0", name: "builds_attempt_positive"
    t.check_constraint "idempotency_key::text = btrim(idempotency_key::text) AND idempotency_key::text <> ''::text", name: "builds_idempotency_key_normalized"
    t.check_constraint "jsonb_typeof(evidence) = 'object'::text", name: "builds_evidence_object"
    t.check_constraint "status::text = 'running'::text AND artifact_digest IS NULL AND finished_at IS NULL OR status::text = 'succeeded'::text AND artifact_digest IS NOT NULL AND finished_at IS NOT NULL OR (status::text = 'failed'::text OR status::text = 'canceled'::text) AND artifact_digest IS NULL AND finished_at IS NOT NULL", name: "builds_lifecycle_consistent"
    t.check_constraint "status::text = 'running'::text OR status::text = 'succeeded'::text OR status::text = 'failed'::text OR status::text = 'canceled'::text", name: "builds_status_allowed"
  end

  create_table "configuration_snapshots", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "environment_id", null: false
    t.jsonb "key_summary", null: false
    t.uuid "organization_id", null: false
    t.string "payload_digest", limit: 64, null: false
    t.text "payload_json", null: false
    t.uuid "project_configuration_version_id"
    t.uuid "project_id", null: false
    t.uuid "service_configuration_version_id"
    t.uuid "service_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_configuration_snapshots_on_created_by_id"
    t.index ["id", "organization_id", "project_id", "environment_id", "service_id"], name: "index_configuration_snapshots_on_tenant_resource_identity", unique: true
    t.index ["service_id", "environment_id", "created_at"], name: "idx_on_service_id_environment_id_created_at_d37534e42d"
    t.check_constraint "jsonb_typeof(key_summary) = 'array'::text", name: "configuration_snapshots_key_summary_array"
    t.check_constraint "payload_digest::text ~ '^[0-9a-f]{64}$'::text", name: "configuration_snapshots_digest_format"
  end

  create_table "configuration_versions", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id", null: false
    t.uuid "environment_id", null: false
    t.jsonb "key_summary", null: false
    t.uuid "organization_id", null: false
    t.string "payload_digest", limit: 64, null: false
    t.text "payload_json", null: false
    t.uuid "project_id", null: false
    t.string "scope_key", limit: 255, null: false
    t.uuid "service_id"
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["created_by_id"], name: "index_configuration_versions_on_created_by_id"
    t.index ["environment_id", "scope_key", "version"], name: "index_configuration_versions_on_environment_scope_version", unique: true
    t.index ["id", "project_id", "environment_id"], name: "index_configuration_versions_on_resource_identity", unique: true
    t.index ["organization_id", "project_id", "environment_id"], name: "index_configuration_versions_on_tenant_scope"
    t.index ["service_id", "environment_id"], name: "index_configuration_versions_on_service_id_and_environment_id"
    t.check_constraint "jsonb_typeof(key_summary) = 'array'::text", name: "configuration_versions_key_summary_array"
    t.check_constraint "payload_digest::text ~ '^[0-9a-f]{64}$'::text", name: "configuration_versions_digest_format"
    t.check_constraint "service_id IS NULL AND scope_key::text = 'project'::text OR service_id IS NOT NULL AND scope_key::text = ('service:'::text || service_id::text)", name: "configuration_versions_scope_matches_service"
    t.check_constraint "version > 0", name: "configuration_versions_version_positive"
  end

  create_table "deployment_transitions", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "actor_id"
    t.string "actor_type", limit: 16, null: false
    t.string "cause", limit: 120, null: false
    t.uuid "correlation_id", null: false
    t.datetime "created_at", null: false
    t.uuid "deployment_id", null: false
    t.jsonb "error", default: {}, null: false
    t.string "from_status", limit: 32
    t.datetime "occurred_at", null: false
    t.integer "sequence", null: false
    t.string "to_status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["correlation_id"], name: "index_deployment_transitions_on_correlation_id"
    t.index ["deployment_id", "sequence"], name: "index_deployment_transitions_on_deployment_id_and_sequence", unique: true
    t.index ["deployment_id"], name: "index_deployment_transitions_on_deployment_id"
    t.check_constraint "actor_type::text = 'user'::text OR actor_type::text = 'system'::text", name: "deployment_transitions_actor_type_allowed"
    t.check_constraint "jsonb_typeof(error) = 'object'::text", name: "deployment_transitions_error_object"
    t.check_constraint "sequence > 0", name: "deployment_transitions_sequence_positive"
  end

  create_table "deployments", id: :uuid, default: nil, force: :cascade do |t|
    t.jsonb "build_settings_snapshot", null: false
    t.string "conclusion", limit: 32
    t.uuid "configuration_snapshot_id", null: false
    t.uuid "correlation_id", null: false
    t.datetime "created_at", null: false
    t.uuid "environment_id", null: false
    t.string "idempotency_key", limit: 255, null: false
    t.integer "lock_version", default: 0, null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id", null: false
    t.jsonb "runtime_policy_snapshot", null: false
    t.uuid "service_id", null: false
    t.string "source_digest", limit: 64, null: false
    t.jsonb "source_snapshot", null: false
    t.string "status", limit: 32, null: false
    t.string "trigger", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["correlation_id"], name: "index_deployments_on_correlation_id", unique: true
    t.index ["id", "correlation_id"], name: "index_deployments_on_transition_identity", unique: true
    t.index ["id", "organization_id", "project_id", "service_id", "environment_id", "configuration_snapshot_id"], name: "index_deployments_on_tenant_resource_identity", unique: true
    t.index ["id", "organization_id"], name: "index_deployments_on_tenant_identity", unique: true
    t.index ["organization_id", "idempotency_key"], name: "index_deployments_on_organization_id_and_idempotency_key", unique: true
    t.index ["organization_id", "status", "created_at"], name: "index_deployments_on_organization_id_and_status_and_created_at"
    t.index ["service_id", "environment_id", "created_at"], name: "idx_on_service_id_environment_id_created_at_858be4d753"
    t.check_constraint "conclusion IS NULL OR conclusion::text = 'succeeded'::text OR conclusion::text = 'failed'::text OR conclusion::text = 'canceled'::text", name: "deployments_conclusion_allowed"
    t.check_constraint "jsonb_typeof(build_settings_snapshot) = 'object'::text", name: "deployments_build_settings_snapshot_object"
    t.check_constraint "jsonb_typeof(runtime_policy_snapshot) = 'object'::text", name: "deployments_runtime_policy_snapshot_object"
    t.check_constraint "jsonb_typeof(source_snapshot) = 'object'::text", name: "deployments_source_snapshot_object"
    t.check_constraint "source_digest::text ~ '^[0-9a-f]{64}$'::text", name: "deployments_source_digest_format"
    t.check_constraint "status::text = 'created'::text OR status::text = 'queued'::text OR status::text = 'preparing'::text OR status::text = 'building'::text OR status::text = 'scanning'::text OR status::text = 'deploying'::text OR status::text = 'verifying'::text OR status::text = 'ready'::text OR status::text = 'promoted'::text OR status::text = 'superseded'::text OR status::text = 'canceling'::text OR status::text = 'canceled'::text OR status::text = 'failed'::text", name: "deployments_status_allowed"
    t.check_constraint "trigger::text = 'manual'::text OR trigger::text = 'webhook'::text OR trigger::text = 'redeploy'::text OR trigger::text = 'rollback'::text", name: "deployments_trigger_allowed"
  end

  create_table "environments", id: :uuid, default: nil, force: :cascade do |t|
    t.string "branch", limit: 255
    t.datetime "created_at", null: false
    t.string "kind", limit: 16, null: false
    t.string "lifecycle_state", limit: 32, default: "active", null: false
    t.string "name", limit: 120, null: false
    t.uuid "project_id", null: false
    t.string "slug", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["id", "project_id"], name: "index_environments_on_id_and_project_id", unique: true
    t.index ["project_id", "branch"], name: "index_environments_on_project_id_and_branch", unique: true, where: "(branch IS NOT NULL)"
    t.index ["project_id", "lifecycle_state"], name: "index_environments_on_project_id_and_lifecycle_state"
    t.index ["project_id", "slug"], name: "index_environments_on_project_id_and_slug", unique: true
    t.index ["project_id"], name: "index_environments_on_one_production_per_project", unique: true, where: "((kind)::text = 'production'::text)"
    t.index ["project_id"], name: "index_environments_on_one_staging_per_project", unique: true, where: "((kind)::text = 'staging'::text)"
    t.index ["project_id"], name: "index_environments_on_project_id"
    t.check_constraint "branch IS NULL OR branch::text = btrim(branch::text) AND branch::text <> ''::text", name: "environments_branch_normalized"
    t.check_constraint "btrim(name::text) <> ''::text", name: "environments_name_present"
    t.check_constraint "kind::text = 'production'::text OR kind::text = 'staging'::text OR kind::text = 'custom'::text", name: "environments_kind_allowed"
    t.check_constraint "lifecycle_state::text = 'active'::text OR lifecycle_state::text = 'deletion_requested'::text OR lifecycle_state::text = 'draining'::text OR lifecycle_state::text = 'deleting_resources'::text OR lifecycle_state::text = 'tombstoned'::text OR lifecycle_state::text = 'permanently_deleted'::text", name: "environments_lifecycle_state_allowed"
    t.check_constraint "slug::text = lower(btrim(slug::text)) AND slug::text ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::text", name: "environments_slug_normalized"
  end

  create_table "event_receipts", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "consumed_at"
    t.string "consumer", limit: 120, null: false
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.string "event_type", limit: 255, null: false
    t.uuid "organization_id", null: false
    t.string "payload_digest", limit: 64, null: false
    t.jsonb "result", default: {}, null: false
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["consumer", "event_id"], name: "index_event_receipts_on_consumer_and_event_id", unique: true
    t.index ["organization_id", "consumer", "created_at"], name: "idx_on_organization_id_consumer_created_at_3298b19f34"
    t.index ["organization_id"], name: "index_event_receipts_on_organization_id"
    t.check_constraint "consumer::text ~ '^[a-z][a-z0-9-]*$'::text", name: "event_receipts_consumer_format"
    t.check_constraint "event_type::text ~ '^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+\\.v[1-9][0-9]*$'::text", name: "event_receipts_type_format"
    t.check_constraint "jsonb_typeof(result) = 'object'::text", name: "event_receipts_result_object"
    t.check_constraint "payload_digest::text ~ '^[0-9a-f]{64}$'::text", name: "event_receipts_payload_digest_format"
    t.check_constraint "status::text = 'processing'::text AND consumed_at IS NULL OR status::text = 'completed'::text AND consumed_at IS NOT NULL", name: "event_receipts_lifecycle_consistent"
    t.check_constraint "status::text = 'processing'::text OR status::text = 'completed'::text", name: "event_receipts_status_allowed"
  end

  create_table "git_installations", id: :uuid, default: nil, force: :cascade do |t|
    t.string "account_id", limit: 255, null: false
    t.string "account_login", limit: 255, null: false
    t.string "account_type", limit: 32, null: false
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.jsonb "permissions", default: {}, null: false
    t.string "provider", limit: 32, null: false
    t.string "provider_installation_id", limit: 255, null: false
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["id", "organization_id"], name: "index_git_installations_on_id_and_organization_id", unique: true
    t.index ["organization_id", "provider"], name: "index_git_installations_on_organization_id_and_provider"
    t.index ["organization_id"], name: "index_git_installations_on_organization_id"
    t.index ["provider", "provider_installation_id"], name: "idx_on_provider_provider_installation_id_eb69f10f93", unique: true
    t.check_constraint "account_type::text = 'organization'::text OR account_type::text = 'user'::text", name: "git_installations_account_type_allowed"
    t.check_constraint "jsonb_typeof(permissions) = 'object'::text", name: "git_installations_permissions_object"
    t.check_constraint "provider::text = 'github'::text", name: "git_installations_provider_allowed"
    t.check_constraint "status::text = 'active'::text OR status::text = 'suspended'::text OR status::text = 'disconnected'::text", name: "git_installations_status_allowed"
  end

  create_table "git_webhook_inboxes", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data", null: false
    t.string "delivery_id", limit: 255, null: false
    t.uuid "deployment_id"
    t.string "event_type", limit: 120, null: false
    t.uuid "git_installation_id", null: false
    t.datetime "occurred_at", null: false
    t.uuid "organization_id", null: false
    t.string "payload_digest", limit: 64, null: false
    t.datetime "processed_at"
    t.string "provider", limit: 32, null: false
    t.string "provider_repository_id", limit: 255
    t.text "safe_error"
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["deployment_id"], name: "index_git_webhook_inboxes_on_deployment_id"
    t.index ["git_installation_id", "provider_repository_id"], name: "idx_on_git_installation_id_provider_repository_id_43d077995b"
    t.index ["organization_id", "status", "created_at"], name: "idx_on_organization_id_status_created_at_b0e5eedb6a"
    t.index ["provider", "delivery_id"], name: "index_git_webhook_inboxes_on_provider_and_delivery_id", unique: true
    t.check_constraint "jsonb_typeof(data) = 'object'::text", name: "git_webhook_inboxes_data_object"
    t.check_constraint "payload_digest::text ~ '^[0-9a-f]{64}$'::text", name: "git_webhook_inboxes_digest_format"
    t.check_constraint "provider::text = 'github'::text", name: "git_webhook_inboxes_provider_allowed"
    t.check_constraint "safe_error IS NULL OR char_length(safe_error) <= 1000", name: "git_webhook_inboxes_safe_error_bounded"
    t.check_constraint "status::text = 'pending'::text AND processed_at IS NULL AND deployment_id IS NULL AND safe_error IS NULL OR status::text = 'processed'::text AND processed_at IS NOT NULL AND safe_error IS NULL OR status::text = 'failed'::text AND processed_at IS NOT NULL AND deployment_id IS NULL AND safe_error = btrim(safe_error) AND safe_error <> ''::text", name: "git_webhook_inboxes_processing_consistent"
    t.check_constraint "status::text = 'pending'::text OR status::text = 'processed'::text OR status::text = 'failed'::text", name: "git_webhook_inboxes_status_allowed"
  end

  create_table "idempotency_records", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", limit: 255, null: false
    t.string "operation", limit: 120, null: false
    t.uuid "organization_id", null: false
    t.string "request_fingerprint", limit: 64, null: false
    t.uuid "resource_id"
    t.string "resource_type", limit: 120
    t.jsonb "response_body", null: false
    t.integer "response_status", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "key"], name: "index_idempotency_records_on_organization_id_and_key", unique: true
    t.index ["organization_id"], name: "index_idempotency_records_on_organization_id"
    t.index ["resource_type", "resource_id"], name: "index_idempotency_records_on_resource_type_and_resource_id"
    t.check_constraint "jsonb_typeof(response_body) = 'object'::text", name: "idempotency_records_response_object"
    t.check_constraint "key::text = btrim(key::text) AND key::text <> ''::text", name: "idempotency_records_key_normalized"
    t.check_constraint "operation::text = btrim(operation::text) AND operation::text <> ''::text", name: "idempotency_records_operation_normalized"
    t.check_constraint "request_fingerprint::text ~ '^[0-9a-f]{64}$'::text", name: "idempotency_records_fingerprint_format"
    t.check_constraint "response_status >= 200 AND response_status <= 599", name: "idempotency_records_status_range"
  end

  create_table "legacy_authentication_sessions", id: :uuid, default: nil, force: :cascade do |t|
    t.string "assurance_level", limit: 32, null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "ip_digest", limit: 64
    t.datetime "issued_at", null: false
    t.string "kind", limit: 16, null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.string "revoked_reason", limit: 120
    t.string "token_digest", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.string "user_agent_digest", limit: 64
    t.uuid "user_id", null: false
    t.index ["token_digest"], name: "index_legacy_authentication_sessions_on_token_digest", unique: true
    t.index ["user_id", "kind", "revoked_at", "expires_at"], name: "index_authentication_sessions_for_user"
    t.index ["user_id"], name: "index_legacy_authentication_sessions_on_user_id"
    t.check_constraint "assurance_level::text = 'single_factor'::text OR assurance_level::text = 'multi_factor'::text", name: "authentication_sessions_assurance_level_allowed"
    t.check_constraint "expires_at > issued_at", name: "authentication_sessions_expiry_after_issue"
    t.check_constraint "ip_digest IS NULL OR ip_digest::text ~ '^[0-9a-f]{64}$'::text", name: "authentication_sessions_ip_digest_format"
    t.check_constraint "kind::text = 'web'::text OR kind::text = 'api'::text", name: "authentication_sessions_kind_allowed"
    t.check_constraint "revoked_at IS NULL AND revoked_reason IS NULL OR revoked_at IS NOT NULL AND revoked_reason IS NOT NULL AND revoked_reason::text = btrim(revoked_reason::text) AND revoked_reason::text <> ''::text", name: "authentication_sessions_revocation_consistent"
    t.check_constraint "token_digest::text ~ '^[0-9a-f]{64}$'::text", name: "authentication_sessions_token_digest_format"
    t.check_constraint "user_agent_digest IS NULL OR user_agent_digest::text ~ '^[0-9a-f]{64}$'::text", name: "authentication_sessions_user_agent_digest_format"
  end

  create_table "legacy_login_challenges", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "email", limit: 320, null: false
    t.datetime "expires_at", null: false
    t.string "purpose", limit: 32, null: false
    t.string "requested_ip_digest", limit: 64
    t.text "token"
    t.string "token_digest", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["email", "created_at"], name: "index_legacy_login_challenges_on_email_and_created_at"
    t.index ["requested_ip_digest", "created_at"], name: "idx_on_requested_ip_digest_created_at_373f3599c0"
    t.index ["token_digest"], name: "index_legacy_login_challenges_on_token_digest", unique: true
    t.check_constraint "consumed_at IS NULL AND token IS NOT NULL OR consumed_at IS NOT NULL AND token IS NULL", name: "login_challenges_consumption_consistent"
    t.check_constraint "email::text = lower(btrim(email::text)) AND email::text <> ''::text", name: "login_challenges_email_normalized"
    t.check_constraint "expires_at > created_at", name: "login_challenges_expiry_after_creation"
    t.check_constraint "purpose::text = 'email_login'::text", name: "login_challenges_purpose_allowed"
    t.check_constraint "requested_ip_digest IS NULL OR requested_ip_digest::text ~ '^[0-9a-f]{64}$'::text", name: "login_challenges_ip_digest_format"
    t.check_constraint "token_digest::text ~ '^[0-9a-f]{64}$'::text", name: "login_challenges_token_digest_format"
  end

  create_table "memberships", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "organization_id", null: false
    t.string "role", limit: 16, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["organization_id", "role"], name: "index_memberships_on_organization_id_and_role"
    t.index ["organization_id", "user_id"], name: "index_memberships_on_organization_id_and_user_id", unique: true
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
    t.index ["user_id"], name: "index_memberships_on_user_id"
    t.check_constraint "role::text = 'owner'::text OR role::text = 'admin'::text OR role::text = 'member'::text", name: "memberships_role_allowed"
  end

  create_table "organizations", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", limit: 120, null: false
    t.datetime "updated_at", null: false
    t.check_constraint "btrim(name::text) <> ''::text", name: "organizations_name_present"
  end

  create_table "outbox_events", id: :uuid, default: nil, force: :cascade do |t|
    t.integer "attempt_count", default: 0, null: false
    t.datetime "available_at", null: false
    t.uuid "claim_request_id"
    t.uuid "claim_token"
    t.uuid "correlation_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "data", null: false
    t.string "data_digest", limit: 64, null: false
    t.string "event_type", limit: 255, null: false
    t.string "idempotency_key", limit: 255, null: false
    t.string "last_error", limit: 1000
    t.integer "lock_version", default: 0, null: false
    t.datetime "locked_until"
    t.datetime "occurred_at", null: false
    t.uuid "organization_id", null: false
    t.string "producer", limit: 63, null: false
    t.datetime "published_at"
    t.uuid "resource_id", null: false
    t.integer "schema_version", default: 1, null: false
    t.string "status", limit: 32, default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["claim_request_id"], name: "index_outbox_events_on_claim_request_id", unique: true, where: "(claim_request_id IS NOT NULL)"
    t.index ["organization_id", "producer", "idempotency_key"], name: "index_outbox_events_on_producer_idempotency", unique: true
    t.index ["organization_id", "status", "created_at"], name: "idx_on_organization_id_status_created_at_1118c31bba"
    t.index ["organization_id"], name: "index_outbox_events_on_organization_id"
    t.index ["status", "available_at", "locked_until", "created_at"], name: "index_outbox_events_for_dispatch"
    t.check_constraint "attempt_count >= 0", name: "outbox_events_attempt_count_nonnegative"
    t.check_constraint "data_digest::text ~ '^[0-9a-f]{64}$'::text", name: "outbox_events_data_digest_format"
    t.check_constraint "event_type::text ~ '^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+\\.v[1-9][0-9]*$'::text", name: "outbox_events_type_format"
    t.check_constraint "idempotency_key::text = btrim(idempotency_key::text) AND idempotency_key::text <> ''::text", name: "outbox_events_idempotency_key_normalized"
    t.check_constraint "jsonb_typeof(data) = 'object'::text", name: "outbox_events_data_object"
    t.check_constraint "producer::text ~ '^[a-z][a-z0-9-]*$'::text", name: "outbox_events_producer_format"
    t.check_constraint "schema_version = 1", name: "outbox_events_schema_version"
    t.check_constraint "status::text <> 'delivering'::text OR claim_request_id IS NOT NULL", name: "outbox_events_delivering_request_present"
    t.check_constraint "status::text = 'pending'::text AND claim_token IS NULL AND locked_until IS NULL AND published_at IS NULL OR status::text = 'delivering'::text AND claim_token IS NOT NULL AND locked_until IS NOT NULL AND published_at IS NULL OR status::text = 'published'::text AND claim_token IS NULL AND locked_until IS NULL AND published_at IS NOT NULL OR status::text = 'dead'::text AND claim_token IS NULL AND locked_until IS NULL AND published_at IS NULL", name: "outbox_events_delivery_state_consistent"
    t.check_constraint "status::text = 'pending'::text OR status::text = 'delivering'::text OR status::text = 'published'::text OR status::text = 'dead'::text", name: "outbox_events_status_allowed"
  end

  create_table "projects", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "lifecycle_state", limit: 32, default: "active", null: false
    t.string "name", limit: 120, null: false
    t.uuid "organization_id", null: false
    t.string "slug", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index "organization_id, lower((name)::text)", name: "index_projects_on_organization_and_lower_name", unique: true
    t.index ["id", "organization_id"], name: "index_projects_on_id_and_organization_id", unique: true
    t.index ["organization_id", "lifecycle_state"], name: "index_projects_on_organization_id_and_lifecycle_state"
    t.index ["organization_id", "slug"], name: "index_projects_on_organization_id_and_slug", unique: true
    t.index ["organization_id"], name: "index_projects_on_organization_id"
    t.check_constraint "btrim(name::text) <> ''::text", name: "projects_name_present"
    t.check_constraint "lifecycle_state::text = 'active'::text OR lifecycle_state::text = 'deletion_requested'::text OR lifecycle_state::text = 'draining'::text OR lifecycle_state::text = 'deleting_resources'::text OR lifecycle_state::text = 'tombstoned'::text OR lifecycle_state::text = 'permanently_deleted'::text", name: "projects_lifecycle_state_allowed"
    t.check_constraint "slug::text = lower(btrim(slug::text)) AND slug::text ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::text", name: "projects_slug_normalized"
  end

  create_table "repository_connections", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_branch", limit: 255, null: false
    t.string "full_name", limit: 255, null: false
    t.uuid "git_installation_id", null: false
    t.string "name", limit: 255, null: false
    t.uuid "organization_id", null: false
    t.string "owner", limit: 255, null: false
    t.boolean "private", null: false
    t.uuid "project_id", null: false
    t.string "provider_repository_id", limit: 255, null: false
    t.uuid "service_id", null: false
    t.string "status", limit: 32, default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["git_installation_id", "provider_repository_id"], name: "index_repository_connections_on_installation_and_repository", unique: true
    t.index ["id", "organization_id"], name: "index_repository_connections_on_id_and_organization_id", unique: true
    t.index ["organization_id", "status"], name: "index_repository_connections_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_repository_connections_on_organization_id"
    t.index ["project_id", "organization_id"], name: "index_repository_connections_on_project_id_and_organization_id"
    t.index ["service_id", "project_id"], name: "index_repository_connections_on_service_id_and_project_id"
    t.index ["service_id"], name: "index_repository_connections_on_service_id", unique: true
    t.check_constraint "status::text = 'active'::text OR status::text = 'removed'::text OR status::text = 'disconnected'::text", name: "repository_connections_status_allowed"
  end

  create_table "revisions", id: :uuid, default: nil, force: :cascade do |t|
    t.string "artifact_digest", limit: 71, null: false
    t.uuid "build_id", null: false
    t.string "cell", limit: 64, null: false
    t.uuid "configuration_snapshot_id", null: false
    t.datetime "created_at", null: false
    t.uuid "deployment_id", null: false
    t.uuid "environment_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.uuid "organization_id", null: false
    t.uuid "project_id", null: false
    t.jsonb "readiness", default: {}, null: false
    t.datetime "ready_at"
    t.string "region", limit: 64, null: false
    t.jsonb "runtime_policy_snapshot", null: false
    t.uuid "service_id", null: false
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["build_id"], name: "index_revisions_on_build_id", unique: true
    t.index ["configuration_snapshot_id"], name: "index_revisions_on_configuration_snapshot_id"
    t.index ["deployment_id"], name: "index_revisions_on_deployment_id"
    t.index ["id", "organization_id", "project_id", "service_id", "environment_id", "status"], name: "index_revisions_on_ready_alias_identity", unique: true
    t.index ["id", "organization_id", "project_id", "service_id", "environment_id"], name: "index_revisions_on_tenant_resource_identity", unique: true
    t.index ["service_id", "environment_id", "status", "created_at"], name: "idx_on_service_id_environment_id_status_created_at_a0972e982e"
    t.check_constraint "artifact_digest::text ~ '^sha256:[0-9a-f]{64}$'::text", name: "revisions_artifact_digest_format"
    t.check_constraint "cell::text = btrim(cell::text) AND cell::text <> ''::text", name: "revisions_cell_normalized"
    t.check_constraint "jsonb_typeof(readiness) = 'object'::text", name: "revisions_readiness_object"
    t.check_constraint "jsonb_typeof(runtime_policy_snapshot) = 'object'::text", name: "revisions_runtime_policy_object"
    t.check_constraint "region::text = btrim(region::text) AND region::text <> ''::text", name: "revisions_region_normalized"
    t.check_constraint "status::text = 'candidate'::text AND ready_at IS NULL OR (status::text = 'ready'::text OR status::text = 'retired'::text) AND ready_at IS NOT NULL", name: "revisions_lifecycle_consistent"
    t.check_constraint "status::text = 'candidate'::text OR status::text = 'ready'::text OR status::text = 'retired'::text", name: "revisions_status_allowed"
  end

  create_table "rodauth_login_claims", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "token_digest", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_rodauth_login_claims_on_token_digest", unique: true
    t.check_constraint "token_digest::text ~ '^[0-9a-f]{64}$'::text", name: "rodauth_login_claims_token_digest_format"
  end

  create_table "services", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "lifecycle_state", limit: 32, default: "active", null: false
    t.string "name", limit: 120, null: false
    t.uuid "project_id", null: false
    t.jsonb "runtime_policy", default: {}, null: false
    t.string "source_reference", limit: 2048, null: false
    t.string "source_type", limit: 8, null: false
    t.datetime "updated_at", null: false
    t.string "workload_type", limit: 16, null: false
    t.index "project_id, lower((name)::text)", name: "index_services_on_project_and_lower_name", unique: true
    t.index ["id", "project_id"], name: "index_services_on_id_and_project_id", unique: true
    t.index ["project_id", "lifecycle_state"], name: "index_services_on_project_id_and_lifecycle_state"
    t.index ["project_id", "workload_type"], name: "index_services_on_project_id_and_workload_type"
    t.index ["project_id"], name: "index_services_on_project_id"
    t.check_constraint "btrim(name::text) <> ''::text", name: "services_name_present"
    t.check_constraint "jsonb_typeof(runtime_policy) = 'object'::text", name: "services_runtime_policy_object"
    t.check_constraint "lifecycle_state::text = 'active'::text OR lifecycle_state::text = 'deletion_requested'::text OR lifecycle_state::text = 'draining'::text OR lifecycle_state::text = 'deleting_resources'::text OR lifecycle_state::text = 'tombstoned'::text OR lifecycle_state::text = 'permanently_deleted'::text", name: "services_lifecycle_state_allowed"
    t.check_constraint "source_reference::text = btrim(source_reference::text) AND source_reference::text <> ''::text", name: "services_source_reference_normalized"
    t.check_constraint "source_type::text = 'git'::text OR source_type::text = 'oci'::text", name: "services_source_type_allowed"
    t.check_constraint "workload_type::text = 'static'::text OR workload_type::text = 'web'::text OR workload_type::text = 'private'::text OR workload_type::text = 'worker'::text OR workload_type::text = 'cron'::text OR workload_type::text = 'job'::text", name: "services_workload_type_allowed"
  end

  create_table "user_active_session_keys", primary_key: ["user_id", "session_id"], force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "last_use", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "session_id", null: false
    t.uuid "user_id", null: false
    t.index ["user_id"], name: "index_user_active_session_keys_on_user_id"
  end

  create_table "user_email_auth_keys", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "deadline", null: false
    t.datetime "email_last_sent", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "key", null: false
  end

  create_table "user_identities", id: :uuid, default: nil, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "provider", limit: 64, null: false
    t.string "uid", limit: 255, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["provider", "uid"], name: "index_user_identities_on_provider_and_uid", unique: true
    t.index ["user_id", "provider"], name: "index_user_identities_on_user_id_and_provider", unique: true
    t.index ["user_id"], name: "index_user_identities_on_user_id"
  end

  create_table "users", id: :uuid, default: nil, force: :cascade do |t|
    t.string "authentication_state", limit: 32, default: "active", null: false
    t.datetime "created_at", null: false
    t.string "email", limit: 320, null: false
    t.string "name", limit: 120, null: false
    t.string "password_hash", limit: 255
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.index ["authentication_state"], name: "index_users_on_authentication_state"
    t.check_constraint "authentication_state::text = ANY (ARRAY['active'::character varying::text, 'bootstrap_candidate'::character varying::text, 'blocked'::character varying::text])", name: "users_authentication_state_allowed"
    t.check_constraint "btrim(name::text) <> ''::text", name: "users_name_present"
    t.check_constraint "email::text = lower(btrim(email::text))", name: "users_email_normalized"
  end

  add_foreign_key "aliases", "environments", column: ["environment_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "aliases", "projects", column: ["project_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "aliases", "revisions", column: ["current_revision_id", "organization_id", "project_id", "service_id", "environment_id", "current_revision_status"], primary_key: ["id", "organization_id", "project_id", "service_id", "environment_id", "status"], on_delete: :restrict
  add_foreign_key "aliases", "revisions", column: ["previous_revision_id", "organization_id", "project_id", "service_id", "environment_id", "previous_revision_status"], primary_key: ["id", "organization_id", "project_id", "service_id", "environment_id", "status"], on_delete: :restrict
  add_foreign_key "aliases", "services", column: ["service_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "builds", "deployments", column: ["deployment_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "builds", "organizations", on_delete: :restrict
  add_foreign_key "configuration_snapshots", "configuration_versions", column: ["project_configuration_version_id", "project_id", "environment_id"], primary_key: ["id", "project_id", "environment_id"], on_delete: :restrict
  add_foreign_key "configuration_snapshots", "configuration_versions", column: ["service_configuration_version_id", "project_id", "environment_id"], primary_key: ["id", "project_id", "environment_id"], on_delete: :restrict
  add_foreign_key "configuration_snapshots", "environments", column: ["environment_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "configuration_snapshots", "projects", column: ["project_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "configuration_snapshots", "services", column: ["service_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "configuration_snapshots", "users", column: "created_by_id", on_delete: :restrict
  add_foreign_key "configuration_versions", "environments", column: ["environment_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "configuration_versions", "projects", column: ["project_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "configuration_versions", "services", column: ["service_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "configuration_versions", "users", column: "created_by_id", on_delete: :restrict
  add_foreign_key "deployment_transitions", "deployments", column: ["deployment_id", "correlation_id"], primary_key: ["id", "correlation_id"], on_delete: :restrict
  add_foreign_key "deployment_transitions", "deployments", on_delete: :restrict
  add_foreign_key "deployments", "configuration_snapshots", column: ["configuration_snapshot_id", "organization_id", "project_id", "environment_id", "service_id"], primary_key: ["id", "organization_id", "project_id", "environment_id", "service_id"], on_delete: :restrict
  add_foreign_key "deployments", "environments", column: ["environment_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "deployments", "projects", column: ["project_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "deployments", "services", column: ["service_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "environments", "projects", on_delete: :restrict
  add_foreign_key "event_receipts", "organizations", on_delete: :restrict
  add_foreign_key "git_installations", "organizations", on_delete: :restrict
  add_foreign_key "git_webhook_inboxes", "deployments", column: ["deployment_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "git_webhook_inboxes", "git_installations", column: ["git_installation_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "idempotency_records", "organizations", on_delete: :restrict
  add_foreign_key "legacy_authentication_sessions", "users", on_delete: :restrict
  add_foreign_key "memberships", "organizations", on_delete: :restrict
  add_foreign_key "memberships", "users", on_delete: :restrict
  add_foreign_key "outbox_events", "organizations", on_delete: :restrict
  add_foreign_key "projects", "organizations", on_delete: :restrict
  add_foreign_key "repository_connections", "git_installations", column: ["git_installation_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "repository_connections", "organizations", on_delete: :restrict
  add_foreign_key "repository_connections", "projects", column: ["project_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "repository_connections", "services", column: ["service_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "revisions", "builds", column: ["build_id", "deployment_id", "organization_id", "artifact_digest"], primary_key: ["id", "deployment_id", "organization_id", "artifact_digest"], on_delete: :restrict
  add_foreign_key "revisions", "configuration_snapshots", column: ["configuration_snapshot_id", "organization_id", "project_id", "environment_id", "service_id"], primary_key: ["id", "organization_id", "project_id", "environment_id", "service_id"], on_delete: :restrict
  add_foreign_key "revisions", "deployments", column: ["deployment_id", "organization_id", "project_id", "service_id", "environment_id", "configuration_snapshot_id"], primary_key: ["id", "organization_id", "project_id", "service_id", "environment_id", "configuration_snapshot_id"], on_delete: :restrict
  add_foreign_key "revisions", "environments", column: ["environment_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "revisions", "projects", column: ["project_id", "organization_id"], primary_key: ["id", "organization_id"], on_delete: :restrict
  add_foreign_key "revisions", "services", column: ["service_id", "project_id"], primary_key: ["id", "project_id"], on_delete: :restrict
  add_foreign_key "services", "projects", on_delete: :restrict
  add_foreign_key "user_active_session_keys", "users", on_delete: :cascade
  add_foreign_key "user_email_auth_keys", "users", column: "id", on_delete: :cascade
  add_foreign_key "user_identities", "users", on_delete: :cascade
end
