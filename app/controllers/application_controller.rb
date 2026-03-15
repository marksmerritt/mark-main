class ApplicationController < ActionController::Base
  include ApiConnected

  allow_browser versions: :modern
end
