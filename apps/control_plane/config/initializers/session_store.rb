Rails.application.config.session_store :cookie_store,
  key: "_lrail_control_plane_session",
  expire_after: ENV.fetch("AUTH_TOKEN_TTL_DAYS", 30).to_i.days,
  httponly: true,
  same_site: :lax,
  secure: Rails.env.production?
