class AddLocalProviderCommandClaims < ActiveRecord::Migration[8.1]
  def change
    add_column :outbox_events, :claim_request_id, :uuid
    add_index :outbox_events,
      :claim_request_id,
      unique: true,
      where: "claim_request_id IS NOT NULL"
    add_check_constraint :outbox_events,
      "status <> 'delivering' OR claim_request_id IS NOT NULL",
      name: "outbox_events_delivering_request_present"
  end
end
