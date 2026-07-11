class CreateOutboxEventsAndEventReceipts < ActiveRecord::Migration[8.1]
  def change
    change_column_null :configuration_snapshots, :created_by_id, true

    add_reference :git_webhook_inboxes, :deployment, type: :uuid
    add_foreign_key :git_webhook_inboxes, :deployments,
      column: [ :deployment_id, :organization_id ],
      primary_key: [ :id, :organization_id ],
      on_delete: :restrict
    add_check_constraint :git_webhook_inboxes,
      "(status = 'pending' AND processed_at IS NULL AND deployment_id IS NULL AND safe_error IS NULL) OR " \
        "(status = 'processed' AND processed_at IS NOT NULL AND safe_error IS NULL) OR " \
        "(status = 'failed' AND processed_at IS NOT NULL AND deployment_id IS NULL AND " \
        "safe_error = btrim(safe_error) AND safe_error <> '')",
      name: "git_webhook_inboxes_processing_consistent"
    add_check_constraint :git_webhook_inboxes,
      "safe_error IS NULL OR char_length(safe_error) <= 1000",
      name: "git_webhook_inboxes_safe_error_bounded"

    create_table :outbox_events, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.uuid :resource_id, null: false
      table.string :event_type, null: false, limit: 255
      table.uuid :correlation_id, null: false
      table.string :idempotency_key, null: false, limit: 255
      table.string :producer, null: false, limit: 63
      table.integer :schema_version, null: false, default: 1
      table.jsonb :data, null: false
      table.string :data_digest, null: false, limit: 64
      table.datetime :occurred_at, null: false
      table.string :status, null: false, limit: 32, default: "pending"
      table.integer :attempt_count, null: false, default: 0
      table.datetime :available_at, null: false
      table.datetime :locked_until
      table.uuid :claim_token
      table.datetime :published_at
      table.string :last_error, limit: 1000
      table.integer :lock_version, null: false, default: 0
      table.timestamps
    end

    add_index :outbox_events,
      [ :organization_id, :producer, :idempotency_key ],
      unique: true,
      name: "index_outbox_events_on_producer_idempotency"
    add_index :outbox_events, [ :organization_id, :status, :created_at ]
    add_index :outbox_events, [ :status, :available_at, :locked_until, :created_at ], name: "index_outbox_events_for_dispatch"
    add_check_constraint :outbox_events,
      "event_type ~ '^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+\\.v[1-9][0-9]*$'",
      name: "outbox_events_type_format"
    add_check_constraint :outbox_events,
      "producer ~ '^[a-z][a-z0-9-]*$'",
      name: "outbox_events_producer_format"
    add_check_constraint :outbox_events,
      "idempotency_key = btrim(idempotency_key) AND idempotency_key <> ''",
      name: "outbox_events_idempotency_key_normalized"
    add_check_constraint :outbox_events, "schema_version = 1", name: "outbox_events_schema_version"
    add_check_constraint :outbox_events, "jsonb_typeof(data) = 'object'", name: "outbox_events_data_object"
    add_check_constraint :outbox_events,
      "data_digest ~ '^[0-9a-f]{64}$'",
      name: "outbox_events_data_digest_format"
    add_check_constraint :outbox_events,
      "status = 'pending' OR status = 'delivering' OR status = 'published' OR status = 'dead'",
      name: "outbox_events_status_allowed"
    add_check_constraint :outbox_events, "attempt_count >= 0", name: "outbox_events_attempt_count_nonnegative"
    add_check_constraint :outbox_events,
      "(status = 'pending' AND claim_token IS NULL AND locked_until IS NULL AND published_at IS NULL) OR " \
        "(status = 'delivering' AND claim_token IS NOT NULL AND locked_until IS NOT NULL AND published_at IS NULL) OR " \
        "(status = 'published' AND claim_token IS NULL AND locked_until IS NULL AND published_at IS NOT NULL) OR " \
        "(status = 'dead' AND claim_token IS NULL AND locked_until IS NULL AND published_at IS NULL)",
      name: "outbox_events_delivery_state_consistent"

    create_table :event_receipts, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.string :consumer, null: false, limit: 120
      table.uuid :event_id, null: false
      table.string :event_type, null: false, limit: 255
      table.string :payload_digest, null: false, limit: 64
      table.string :status, null: false, limit: 32
      table.jsonb :result, null: false, default: {}
      table.datetime :consumed_at
      table.timestamps
    end

    add_index :event_receipts, [ :consumer, :event_id ], unique: true
    add_index :event_receipts, [ :organization_id, :consumer, :created_at ]
    add_check_constraint :event_receipts,
      "consumer ~ '^[a-z][a-z0-9-]*$'",
      name: "event_receipts_consumer_format"
    add_check_constraint :event_receipts,
      "event_type ~ '^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+\\.v[1-9][0-9]*$'",
      name: "event_receipts_type_format"
    add_check_constraint :event_receipts,
      "payload_digest ~ '^[0-9a-f]{64}$'",
      name: "event_receipts_payload_digest_format"
    add_check_constraint :event_receipts,
      "status = 'processing' OR status = 'completed'",
      name: "event_receipts_status_allowed"
    add_check_constraint :event_receipts, "jsonb_typeof(result) = 'object'", name: "event_receipts_result_object"
    add_check_constraint :event_receipts,
      "(status = 'processing' AND consumed_at IS NULL) OR (status = 'completed' AND consumed_at IS NOT NULL)",
      name: "event_receipts_lifecycle_consistent"
  end
end
