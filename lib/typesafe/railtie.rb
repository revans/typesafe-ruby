# frozen_string_literal: true

require "rails/railtie"

module TypeSafe
  # Loads TypeSafe settings from Rails credentials at boot, before
  # config/initializers run, so an initializer can still override them.
  class Railtie < ::Rails::Railtie
    initializer "typesafe.credentials", before: :load_config_initializers do |app|
      TypeSafe::RailsCredentials.apply(app.credentials)
    end
  end
end
