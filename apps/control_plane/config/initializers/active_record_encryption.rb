base_key = ENV["RAILS_ENCRYPTION_KEY"].presence || ENV["ENCRYPTION_KEY"].presence
raise "RAILS_ENCRYPTION_KEY or ENCRYPTION_KEY is required" if base_key.blank?

Rails.application.config.active_record.encryption.primary_key =
  Digest::SHA256.hexdigest("lrail:active-record:primary:#{base_key}")
Rails.application.config.active_record.encryption.deterministic_key =
  Digest::SHA256.hexdigest("lrail:active-record:deterministic:#{base_key}")
Rails.application.config.active_record.encryption.key_derivation_salt =
  Digest::SHA256.hexdigest("lrail:active-record:salt:#{base_key}")
Rails.application.config.active_record.encryption.support_unencrypted_data = false
