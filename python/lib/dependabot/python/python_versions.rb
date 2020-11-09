# frozen_string_literal: true

module Dependabot
  module Python
    module PythonVersions
      PRE_INSTALLED_PYTHON_VERSIONS = %w(
        3.9.0 2.7.18
      ).freeze

      # Due to an OpenSSL issue we can only install the following versions in
      # the Dependabot container.
      SUPPORTED_VERSIONS = %w(
        3.9.0
        3.8.6 3.8.5 3.8.4 3.8.3 3.8.2 3.8.1 3.8.0
        3.7.9 3.7.8 3.7.7 3.7.6 3.7.5 3.7.4 3.7.3 3.7.2 3.7.1 3.7.0
        3.6.12 3.6.11 3.6.10 3.6.9 3.6.8 3.6.7 3.6.6 3.6.5 3.6.4 3.6.3 3.6.2
        3.6.1 3.6.0 3.5.10 3.5.8 3.5.7 3.5.6 3.5.5 3.5.4 3.5.3
        2.7.18 2.7.17 2.7.16 2.7.15 2.7.14 2.7.13
      ).freeze

      # This list gets iterated through to find a valid version, so we have
      # the two pre-installed versions listed first.
      SUPPORTED_VERSIONS_TO_ITERATE =
        [
          *PRE_INSTALLED_PYTHON_VERSIONS.select { |v| v.start_with?("3") },
          *SUPPORTED_VERSIONS
        ].freeze
    end
  end
end
