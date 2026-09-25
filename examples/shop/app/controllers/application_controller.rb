# The developer console: the host application's only code. It composes the shop's modules
# and reads them only through their public APIs.
class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    def back_to_console(notice) = redirect_back_or_to(root_path, notice: notice)
end
