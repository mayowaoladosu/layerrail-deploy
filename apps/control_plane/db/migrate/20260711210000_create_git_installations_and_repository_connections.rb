class CreateGitInstallationsAndRepositoryConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :git_installations, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.string :provider, null: false, limit: 32
      table.string :provider_installation_id, null: false, limit: 255
      table.string :account_id, null: false, limit: 255
      table.string :account_login, null: false, limit: 255
      table.string :account_type, null: false, limit: 32
      table.string :status, null: false, limit: 32
      table.jsonb :permissions, null: false, default: {}
      table.timestamps
    end

    add_index :git_installations, [ :provider, :provider_installation_id ], unique: true
    add_index :git_installations, [ :id, :organization_id ], unique: true
    add_index :git_installations, [ :organization_id, :provider ]
    add_check_constraint :git_installations, "provider = 'github'", name: "git_installations_provider_allowed"
    add_check_constraint :git_installations,
      "status = 'active' OR status = 'suspended' OR status = 'disconnected'",
      name: "git_installations_status_allowed"
    add_check_constraint :git_installations,
      "account_type = 'organization' OR account_type = 'user'",
      name: "git_installations_account_type_allowed"
    add_check_constraint :git_installations,
      "jsonb_typeof(permissions) = 'object'",
      name: "git_installations_permissions_object"

    create_table :repository_connections, id: false do |table|
      table.primary_key :id, :uuid, default: nil
      table.references :organization, null: false, type: :uuid, foreign_key: { on_delete: :restrict }
      table.uuid :git_installation_id, null: false
      table.uuid :project_id, null: false
      table.uuid :service_id, null: false
      table.string :provider_repository_id, null: false, limit: 255
      table.string :owner, null: false, limit: 255
      table.string :name, null: false, limit: 255
      table.string :full_name, null: false, limit: 255
      table.boolean :private, null: false
      table.string :default_branch, null: false, limit: 255
      table.string :status, null: false, limit: 32, default: "active"
      table.timestamps
    end

    add_index :repository_connections, :service_id, unique: true
    add_index :repository_connections, [ :id, :organization_id ], unique: true
    add_index :repository_connections, [ :project_id, :organization_id ]
    add_index :repository_connections, [ :service_id, :project_id ]
    add_index :repository_connections,
      [ :git_installation_id, :provider_repository_id ],
      unique: true,
      name: "index_repository_connections_on_installation_and_repository"
    add_index :repository_connections, [ :organization_id, :status ]
    add_check_constraint :repository_connections,
      "status = 'active' OR status = 'removed' OR status = 'disconnected'",
      name: "repository_connections_status_allowed"

    add_index :projects, [ :id, :organization_id ], unique: true
    add_index :services, [ :id, :project_id ], unique: true
    add_foreign_key :repository_connections,
      :git_installations,
      column: [ :git_installation_id, :organization_id ],
      primary_key: [ :id, :organization_id ],
      on_delete: :restrict
    add_foreign_key :repository_connections,
      :projects,
      column: [ :project_id, :organization_id ],
      primary_key: [ :id, :organization_id ],
      on_delete: :restrict
    add_foreign_key :repository_connections,
      :services,
      column: [ :service_id, :project_id ],
      primary_key: [ :id, :project_id ],
      on_delete: :restrict
  end
end
