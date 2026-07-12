class LegacyAssetsController < ActionController::Base
  skip_after_action :verify_same_origin_request

  ROOT = Rails.configuration.x.legacy_ui_root.join("assets").freeze
  ASSETS = {
    "styles.css" => [ ROOT.join("styles.css"), "text/css; charset=utf-8" ],
    "basecoat.min.js" => [ ROOT.join("basecoat.min.js"), "application/javascript; charset=utf-8" ],
    "alpine.min.js" => [ ROOT.join("alpine.min.js"), "application/javascript; charset=utf-8" ],
    "htmx.min.js" => [ ROOT.join("htmx.min.js"), "application/javascript; charset=utf-8" ],
    "htmx-sse.min.js" => [ ROOT.join("htmx-sse.min.js"), "application/javascript; charset=utf-8" ],
    "favicon.svg" => [ ROOT.join("favicon.svg"), "image/svg+xml" ],
    "apple-touch-icon.png" => [ ROOT.join("apple-touch-icon.png"), "image/png" ],
    "social.png" => [ ROOT.join("social.png"), "image/png" ]
  }.freeze

  def show
    asset = ASSETS[params[:filename].to_s]
    return head :not_found unless asset

    path, type = asset
    return head :not_found unless path.file?

    response.set_header("Cache-Control", "public, max-age=300")
    send_file path, type:, disposition: "inline"
  end
end
