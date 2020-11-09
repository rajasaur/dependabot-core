# frozen_string_literal: true

require "excon"

require "dependabot/bundler/update_checker"
require "dependabot/bundler/native_helpers"
require "dependabot/shared_helpers"
require "dependabot/errors"

module Dependabot
  module Bundler
    class UpdateChecker
      module SharedBundlerHelpers
        GIT_REGEX = /reset --hard [^\s]*` in directory (?<path>[^\s]*)/.freeze
        GIT_REF_REGEX = /not exist in the repository (?<path>[^\s]*)\./.freeze
        PATH_REGEX = /The path `(?<path>.*)` does not exist/.freeze

        module BundlerErrorPatterns
          MISSING_AUTH_REGEX =
            /bundle config (?<source>.*) username:password/.freeze
          BAD_AUTH_REGEX =
            /Bad username or password for (?<source>.*)\.$/.freeze
          BAD_CERT_REGEX =
            /verify the SSL certificate for (?<source>.*)\.$/.freeze
          HTTP_ERR_REGEX =
            /Could not fetch specs from (?<source>.*)$/.freeze
        end

        RETRYABLE_ERRORS = %w(
          Bundler::HTTPError
          Bundler::Fetcher::FallbackError
        ).freeze
        RETRYABLE_PRIVATE_REGISTRY_ERRORS = %w(
          Bundler::GemNotFound
          Gem::InvalidSpecificationException
          Bundler::VersionConflict
          Bundler::HTTPError
          Bundler::Fetcher::FallbackError
        ).freeze

        attr_reader :dependency_files, :repo_contents_path, :credentials

        #########################
        # Bundler context setup #
        #########################

        def in_a_native_bundler_context(error_handling: true)
          SharedHelpers.
            in_a_temporary_repo_directory(base_directory,
                                          repo_contents_path) do |tmp_dir|
            write_temporary_dependency_files

            yield(tmp_dir)
          end
        rescue SharedHelpers::HelperSubprocessFailed => e
          retry_count ||= 0
          retry_count += 1
          sleep(rand(1.0..5.0)) && retry if retryable_error?(e) && retry_count <= 2

          error_handling ? handle_bundler_errors(e) : raise
        end

        def base_directory
          dependency_files.first.directory
        end

        def retryable_error?(error)
          return true if error.error_class == "JSON::ParserError"
          return true if RETRYABLE_ERRORS.include?(error.error_class)

          return false unless RETRYABLE_PRIVATE_REGISTRY_ERRORS.include?(error.error_class)

          private_registry_credentials.any?
        end

        # rubocop:disable Metrics/CyclomaticComplexity
        # rubocop:disable Metrics/PerceivedComplexity
        # rubocop:disable Metrics/AbcSize
        # rubocop:disable Metrics/MethodLength
        def handle_bundler_errors(error)
          if error.error_class == "JSON::ParserError"
            msg = "Error evaluating your dependency files: #{error.message}"
            raise Dependabot::DependencyFileNotEvaluatable, msg
          end

          msg = error.error_class + " with message: " + error.message

          case error.error_class
          when "Bundler::Dsl::DSLError", "Bundler::GemspecError"
            # We couldn't evaluate the Gemfile, let alone resolve it
            raise Dependabot::DependencyFileNotEvaluatable, msg
          when "Bundler::Source::Git::MissingGitRevisionError"
            gem_name =
              error.message.match(GIT_REF_REGEX).
              named_captures["path"].
              split("/").last
            raise GitDependencyReferenceNotFound, gem_name
          when "Bundler::PathError"
            gem_name =
              error.message.match(PATH_REGEX).
              named_captures["path"].
              split("/").last.split("-")[0..-2].join
            raise Dependabot::PathDependenciesNotReachable, [gem_name]
          when "Bundler::Source::Git::GitCommandError"
            if error.message.match?(GIT_REGEX)
              # We couldn't find the specified branch / commit (or the two
              # weren't compatible).
              gem_name =
                error.message.match(GIT_REGEX).
                named_captures["path"].
                split("/").last.split("-")[0..-2].join
              raise GitDependencyReferenceNotFound, gem_name
            end

            bad_uris = inaccessible_git_dependencies.map do |spec|
              spec.fetch("uri")
            end
            raise unless bad_uris.any?

            # We don't have access to one of repos required
            raise Dependabot::GitDependenciesNotReachable, bad_uris.uniq
          when "Bundler::GemNotFound", "Gem::InvalidSpecificationException",
               "Bundler::VersionConflict", "Bundler::CyclicDependencyError"
            # Bundler threw an error during resolution. Any of:
            # - the gem doesn't exist in any of the specified sources
            # - the gem wasn't specified properly
            # - the gem was specified at an incompatible version
            raise Dependabot::DependencyFileNotResolvable, msg
          when "Bundler::Fetcher::AuthenticationRequiredError"
            regex = BundlerErrorPatterns::MISSING_AUTH_REGEX
            source = error.message.match(regex)[:source]
            raise Dependabot::PrivateSourceAuthenticationFailure, source
          when "Bundler::Fetcher::BadAuthenticationError"
            regex = BundlerErrorPatterns::BAD_AUTH_REGEX
            source = error.message.match(regex)[:source]
            raise Dependabot::PrivateSourceAuthenticationFailure, source
          when "Bundler::Fetcher::CertificateFailureError"
            regex = BundlerErrorPatterns::BAD_CERT_REGEX
            source = error.message.match(regex)[:source]
            raise Dependabot::PrivateSourceCertificateFailure, source
          when "Bundler::HTTPError"
            regex = BundlerErrorPatterns::HTTP_ERR_REGEX
            if error.message.match?(regex)
              source = error.message.match(regex)[:source]
              raise if source.end_with?("rubygems.org/")

              raise Dependabot::PrivateSourceTimedOut, source
            end

            # JFrog can serve a 403 if the credentials provided are good but
            # don't have access to a particular gem.
            raise unless error.message.include?("permitted to deploy")
            raise unless jfrog_source

            raise Dependabot::PrivateSourceAuthenticationFailure, jfrog_source
          else raise
          end
        end
        # rubocop:enable Metrics/CyclomaticComplexity
        # rubocop:enable Metrics/PerceivedComplexity
        # rubocop:enable Metrics/AbcSize
        # rubocop:enable Metrics/MethodLength

        def inaccessible_git_dependencies
          in_a_native_bundler_context(error_handling: false) do |tmp_dir|
            git_specs = SharedHelpers.run_helper_subprocess(
              command: NativeHelpers.helper_path,
              function: "git_specs",
              args: {
                dir: tmp_dir,
                gemfile_name: gemfile.name,
                credentials: relevant_credentials,
                using_bundler_2: using_bundler_2?
              }
            )
            git_specs.reject do |spec|
              Excon.get(
                spec.fetch("auth_uri"),
                idempotent: true,
                **SharedHelpers.excon_defaults
              ).status == 200
            rescue Excon::Error::Socket, Excon::Error::Timeout
              false
            end
          end
        end

        def jfrog_source
          in_a_native_bundler_context(error_handling: false) do |dir|
            SharedHelpers.run_helper_subprocess(
              command: NativeHelpers.helper_path,
              function: "jfrog_source",
              args: {
                dir: dir,
                gemfile_name: gemfile.name,
                credentials: relevant_credentials,
                using_bundler_2: using_bundler_2?
              }
            )
          end
        end

        def write_temporary_dependency_files
          dependency_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, file.content)
          end

          File.write(lockfile.name, sanitized_lockfile_body) if lockfile
        end

        def relevant_credentials
          [
            *git_source_credentials,
            *private_registry_credentials
          ].select { |cred| cred["password"] || cred["token"] }
        end

        def private_registry_credentials
          credentials.
            select { |cred| cred["type"] == "rubygems_server" }
        end

        def git_source_credentials
          credentials.
            select { |cred| cred["password"] || cred["token"] }.
            select { |cred| cred["type"] == "git_source" }
        end

        def gemfile
          dependency_files.find { |f| f.name == "Gemfile" } ||
            dependency_files.find { |f| f.name == "gems.rb" }
        end

        def lockfile
          dependency_files.find { |f| f.name == "Gemfile.lock" } ||
            dependency_files.find { |f| f.name == "gems.locked" }
        end

        # TODO: Stop sanitizing the lockfile once we have bundler 2 installed
        def sanitized_lockfile_body
          re = FileUpdater::LockfileUpdater::LOCKFILE_ENDING
          lockfile.content.gsub(re, "")
        end

        def using_bundler_2?
          return unless lockfile

          lockfile.content.match?(/BUNDLED WITH\s+2/m)
        end
      end
    end
  end
end
