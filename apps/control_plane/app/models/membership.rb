class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  enum :role, { owner: "owner", admin: "admin", member: "member" }, validate: true

  validates :user_id, uniqueness: { scope: :organization_id }
end
