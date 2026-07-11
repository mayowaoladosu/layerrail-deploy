class CreateIdempotencyRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :idempotency_records, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.string :key, null: false, limit: 255
      table.string :operation, null: false, limit: 120
      table.string :request_fingerprint, null: false, limit: 64
      table.integer :response_status, null: false
      table.jsonb :response_body, null: false
      table.string :resource_type, limit: 120
      table.uuid :resource_id
      table.timestamps
    end

    add_index :idempotency_records, [ :organization_id, :key ], unique: true
    add_index :idempotency_records, [ :resource_type, :resource_id ]
    add_check_constraint :idempotency_records,
      "key = BTRIM(key) AND key <> ''",
      name: "idempotency_records_key_normalized"
    add_check_constraint :idempotency_records,
      "operation = BTRIM(operation) AND operation <> ''",
      name: "idempotency_records_operation_normalized"
    add_check_constraint :idempotency_records,
      "request_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "idempotency_records_fingerprint_format"
    add_check_constraint :idempotency_records,
      "response_status BETWEEN 200 AND 599",
      name: "idempotency_records_status_range"
    add_check_constraint :idempotency_records,
      "jsonb_typeof(response_body) = 'object'",
      name: "idempotency_records_response_object"
  end
end
