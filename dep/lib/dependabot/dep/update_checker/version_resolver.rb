# frozen_string_literal: true

require "toml-rb"
require "open3"
require "dependabot/shared_helpers"
require "dependabot/dep/update_checker"
require "dependabot/errors"

module Dependabot
  module Dep
    class UpdateChecker
      class VersionResolver
        NOT_FOUND_REGEX =
          /failed to list versions for (?<repo_url>.*?):\s+/.freeze
        INDEX_OUT_OF_RANGE_REGEX =
          /panic: runtime error: index out of range.*findValidVersion/m.freeze

        def initialize(dependency:, dependency_files:, credentials:)
          @dependency = dependency
          @dependency_files = dependency_files
          @credentials = credentials
        end

        def latest_resolvable_version
          return @latest_resolvable_version if defined?(@latest_resolvable_version)

          @latest_resolvable_version = fetch_latest_resolvable_version
        end

        private

        attr_reader :dependency, :dependency_files, :credentials

        def fetch_latest_resolvable_version
          base_directory = File.join("src", "project",
                                     dependency_files.first.directory)
          base_parts = base_directory.split("/").length
          updated_version =
            SharedHelpers.in_a_temporary_directory(base_directory) do |dir|
              write_temporary_dependency_files

              SharedHelpers.with_git_configured(credentials: credentials) do
                # Shell out to dep, which handles everything for us, and does
                # so without doing an install (so it's fast).
                command = "dep ensure -update --no-vendor #{dependency.name}"
                dir_parts = dir.realpath.to_s.split("/")
                gopath = File.join(dir_parts[0..-(base_parts + 1)])
                run_shell_command(command, "GOPATH" => gopath)
              end

              new_lockfile_content = File.read("Gopkg.lock")

              get_version_from_lockfile(new_lockfile_content)
            end

          updated_version
        rescue SharedHelpers::HelperSubprocessFailed => e
          handle_dep_errors(e)
        end

        def get_version_from_lockfile(lockfile_content)
          package = TomlRB.parse(lockfile_content).fetch("projects").
                    find { |p| p["name"] == dependency.name }

          version = package["version"]

          if version && version_class.correct?(version.sub(/^v?/, ""))
            version_class.new(version.sub(/^v?/, ""))
          elsif version
            version
          else
            package.fetch("revision")
          end
        end

        def handle_dep_errors(error)
          if error.message.match?(NOT_FOUND_REGEX)
            url = error.message.match(NOT_FOUND_REGEX).
                  named_captures.fetch("repo_url")

            raise Dependabot::GitDependenciesNotReachable, url
          end

          # A dep bug that probably isn't going to be fixed any time soon :-(
          # - https://github.com/golang/dep/issues/1437
          # - https://github.com/golang/dep/issues/649
          # - https://github.com/golang/dep/issues/2041
          # - https://twitter.com/miekg/status/996682296739745792
          return if error.message.match?(INDEX_OUT_OF_RANGE_REGEX)

          raise
        end

        def run_shell_command(command, env = {})
          start = Time.now
          command = SharedHelpers.escape_command(command)
          stdout, process = Open3.capture2e(env, command)
          time_taken = Time.now - start

          # Raise an error with the output from the shell session if dep
          # returns a non-zero status
          return if process.success?

          raise SharedHelpers::HelperSubprocessFailed.new(
            message: stdout,
            error_context: {
              command: command,
              time_taken: time_taken,
              process_exit_value: process.to_s
            }
          )
        end

        def write_temporary_dependency_files
          dependency_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(file.name, file.content)
          end

          File.write("hello.go", dummy_app_content)
        end

        def dummy_app_content
          base = "package main\n\n"\
                 "import \"fmt\"\n\n"

          packages_to_import.each { |nm| base += "import \"#{nm}\"\n\n" }

          base + "func main() {\n  fmt.Printf(\"hello, world\\n\")\n}"
        end

        def packages_to_import
          return [] unless lockfile

          parsed_lockfile = TomlRB.parse(lockfile.content)

          # If the lockfile was created using dep v0.5.0+ then it will tell us
          # exactly which packages to import
          if parsed_lockfile.dig("solve-meta", "input-imports")
            return parsed_lockfile.dig("solve-meta", "input-imports")
          end

          # Otherwise we have no way of knowing, so import everything in the
          # lockfile that isn't marked as internal
          parsed_lockfile.fetch("projects").flat_map do |dep|
            dep["packages"].map do |package|
              next if package.start_with?("internal")

              package == "." ? dep["name"] : File.join(dep["name"], package)
            end.compact
          end
        end

        def lockfile
          @lockfile = dependency_files.find { |f| f.name == "Gopkg.lock" }
        end

        def version_class
          Utils.version_class_for_package_manager(dependency.package_manager)
        end
      end
    end
  end
end
