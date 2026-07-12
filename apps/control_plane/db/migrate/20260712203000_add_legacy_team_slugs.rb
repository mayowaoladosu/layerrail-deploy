require "set"

class AddLegacyTeamSlugs < ActiveRecord::Migration[8.1]
  class MigrationOrganization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  def up
    add_column :organizations, :slug, :string, limit: 64

    MigrationOrganization.reset_column_information
    used = Set.new
    MigrationOrganization.order(:created_at, :id).each do |organization|
      base = organization.name.to_s.parameterize.first(64).delete_suffix("-").presence || "team"
      candidate = base
      if used.include?(candidate)
        suffix = "-#{organization.id.delete("-").first(8)}"
        candidate = "#{base.first(64 - suffix.length).delete_suffix("-")}#{suffix}"
      end
      suffix = 2
      while used.include?(candidate)
        marker = "-#{suffix}"
        candidate = "#{base.first(64 - marker.length).delete_suffix("-")}#{marker}"
        suffix += 1
      end
      organization.update_columns(slug: candidate)
      used << candidate
    end

    change_column_null :organizations, :slug, false
    add_index :organizations, :slug, unique: true
    add_check_constraint :organizations,
      "slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'",
      name: "organizations_slug_format"
  end

  def down
    remove_check_constraint :organizations, name: "organizations_slug_format"
    remove_index :organizations, :slug
    remove_column :organizations, :slug
  end
end
