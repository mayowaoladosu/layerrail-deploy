class CreateGitWebhookInboxes < ActiveRecord::Migration[8.1]
  def change
    create_table :git_webhook_inboxes, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.uuid :organization_id, null: false
      table.uuid :git_installation_id, null: false
      table.string :provider, null: false, limit: 32
      table.string :delivery_id, null: false, limit: 255
      table.string :event_type, null: false, limit: 120
      table.string :provider_repository_id, limit: 255
      table.datetime :occurred_at, null: false
      table.string :payload_digest, null: false, limit: 64
      table.jsonb :data, null: false
      table.string :status, null: false, limit: 32
      table.text :safe_error
      table.datetime :processed_at
      table.timestamps
    end

    add_index :git_webhook_inboxes, [ :provider, :delivery_id ], unique: true
    add_index :git_webhook_inboxes, [ :organization_id, :status, :created_at ]
    add_index :git_webhook_inboxes, [ :git_installation_id, :provider_repository_id ]
    add_check_constraint :git_webhook_inboxes, "provider = 'github'", name: "git_webhook_inboxes_provider_allowed"
    add_check_constraint :git_webhook_inboxes,
      "status = 'pending' OR status = 'processed' OR status = 'failed'",
      name: "git_webhook_inboxes_status_allowed"
    add_check_constraint :git_webhook_inboxes,
      "payload_digest ~ '^[0-9a-f]{64}$'",
      name: "git_webhook_inboxes_digest_format"
    add_check_constraint :git_webhook_inboxes,
      "jsonb_typeof(data) = 'object'",
      name: "git_webhook_inboxes_data_object"
    add_foreign_key :git_webhook_inboxes,
      :git_installations,
      column: [ :git_installation_id, :organization_id ],
      primary_key: [ :id, :organization_id ],
      on_delete: :restrict
  end
end
