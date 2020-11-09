# frozen_string_literal: true

require "spec_helper"
require "shared_contexts"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/bundler/update_checker/version_resolver"

RSpec.describe Dependabot::Bundler::UpdateChecker::VersionResolver do
  let(:resolver) do
    described_class.new(
      dependency: dependency,
      unprepared_dependency_files: dependency_files,
      ignored_versions: ignored_versions,
      credentials: [{
        "type" => "git_source",
        "host" => "github.com",
        "username" => "x-access-token",
        "password" => "token"
      }],
      unlock_requirement: unlock_requirement,
      latest_allowable_version: latest_allowable_version
    )
  end
  let(:dependency_files) { [gemfile, lockfile] }
  let(:ignored_versions) { [] }
  let(:latest_allowable_version) { nil }
  let(:unlock_requirement) { false }

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: current_version,
      requirements: requirements,
      package_manager: "bundler"
    )
  end
  let(:dependency_name) { "business" }
  let(:current_version) { "1.3" }
  let(:requirements) do
    [{
      file: "Gemfile",
      requirement: requirement_string,
      groups: [],
      source: source
    }]
  end
  let(:source) { nil }
  let(:requirement_string) { ">= 0" }

  let(:gemfile) do
    Dependabot::DependencyFile.new(
      content: fixture("ruby", "gemfiles", gemfile_fixture_name),
      name: "Gemfile"
    )
  end
  let(:lockfile) do
    Dependabot::DependencyFile.new(
      content: fixture("ruby", "lockfiles", lockfile_fixture_name),
      name: "Gemfile.lock"
    )
  end
  let(:gemspec) do
    Dependabot::DependencyFile.new(
      content: fixture("ruby", "gemspecs", gemspec_fixture_name),
      name: "example.gemspec"
    )
  end
  let(:gemfile_fixture_name) { "Gemfile" }
  let(:lockfile_fixture_name) { "Gemfile.lock" }
  let(:gemspec_fixture_name) { "example" }
  let(:rubygems_url) { "https://index.rubygems.org/api/v1/" }

  describe "#latest_resolvable_version_details" do
    subject { resolver.latest_resolvable_version_details }

    context "with a rubygems source" do
      context "with a ~> version specified constraining the update" do
        let(:gemfile_fixture_name) { "Gemfile" }
        let(:lockfile_fixture_name) { "Gemfile.lock" }
        let(:requirement_string) { "~> 1.4.0" }

        its([:version]) { is_expected.to eq(Gem::Version.new("1.4.0")) }
      end

      context "with a minor version specified that can update" do
        let(:gemfile_fixture_name) { "minor_version_specified" }
        let(:lockfile_fixture_name) { "Gemfile.lock" }
        let(:requirement_string) { "~> 1.4" }

        its([:version]) { is_expected.to eq(Gem::Version.new("1.18.0")) }
      end

      context "when updating a dep blocked by a sub-dep" do
        let(:gemfile_fixture_name) { "blocked_by_subdep" }
        let(:lockfile_fixture_name) { "blocked_by_subdep.lock" }
        let(:dependency_name) { "dummy-pkg-a" }
        let(:current_version) { "1.0.1" }
        let(:requirements) do
          [{ file: "Gemfile", requirement: ">= 0", groups: [], source: nil }]
        end

        its([:version]) { is_expected.to eq(Gem::Version.new("1.1.0")) }
      end

      context "that only appears in the lockfile" do
        let(:gemfile_fixture_name) { "subdependency" }
        let(:lockfile_fixture_name) { "subdependency.lock" }
        let(:dependency_name) { "i18n" }
        let(:requirements) { [] }

        its([:version]) { is_expected.to eq(Gem::Version.new("0.7.0")) }

        # TODO: https://github.com/dependabot/dependabot-core/issues/2364
        # context "that will be removed if other sub-dependencies are updated" do
        #   let(:gemfile_fixture_name) { "subdependency_change" }
        #   let(:lockfile_fixture_name) { "subdependency_change.lock" }
        #   let(:dependency_name) { "nokogiri" }
        #   let(:requirements) { [] }

        #   pending "is updated" do
        #     expect(subject.version).to eq(Gem::Version.new("1.10.9"))
        #   end
        # end
      end

      context "with a Bundler version specified" do
        let(:gemfile_fixture_name) { "bundler_specified" }
        let(:lockfile_fixture_name) { "bundler_specified.lock" }
        let(:requirement_string) { "~> 1.4.0" }

        its([:version]) { is_expected.to eq(Gem::Version.new("1.4.0")) }

        context "attempting to update Bundler" do
          let(:dependency_name) { "bundler" }
          include_context "stub rubygems versions api"

          its([:version]) { is_expected.to eq(Gem::Version.new("1.16.3")) }

          context "when wrapped in a source block" do
            let(:gemfile_fixture_name) { "bundler_specified_in_source" }
            its([:version]) { is_expected.to eq(Gem::Version.new("1.16.3")) }
          end

          # TODO: https://github.com/dependabot/dependabot-core/issues/2364
          # context "and required by another dependency" do
          #   let(:gemfile_fixture_name) { "bundler_specified_and_required" }
          #   let(:lockfile_fixture_name) do
          #     "bundler_specified_and_required.lock"
          #   end

          #   pending { is_expected.to be_nil }
          # end
        end
      end

      context "with a default gem specified" do
        let(:gemfile_fixture_name) { "default_gem_specified" }
        let(:lockfile_fixture_name) { "default_gem_specified.lock" }
        let(:requirement_string) { "~> 1.4" }

        its([:version]) { is_expected.to eq(Gem::Version.new("1.18.0")) }
      end

      context "with a version conflict at the latest version" do
        let(:gemfile_fixture_name) { "version_conflict_no_req_change" }
        let(:lockfile_fixture_name) { "version_conflict_no_req_change.lock" }
        let(:dependency_name) { "ibandit" }
        let(:requirement_string) { "~> 0.1" }

        # The latest version of ibandit is 0.8.5, but 0.11.28 is the latest
        # version compatible with the version of i18n in the Gemfile.lock.
        its([:version]) { is_expected.to eq(Gem::Version.new("0.11.28")) }

        context "with a gems.rb and gems.locked" do
          let(:gemfile) do
            Dependabot::DependencyFile.new(
              content: fixture("ruby", "gemfiles", gemfile_fixture_name),
              name: "gems.rb"
            )
          end
          let(:lockfile) do
            Dependabot::DependencyFile.new(
              content: fixture("ruby", "lockfiles", lockfile_fixture_name),
              name: "gems.locked"
            )
          end
          let(:requirements) do
            [{
              file: "gems.rb",
              requirement: requirement_string,
              groups: [],
              source: source
            }]
          end

          its([:version]) { is_expected.to eq(Gem::Version.new("0.11.28")) }
        end
      end

      context "with no update possible due to a version conflict" do
        let(:gemfile_fixture_name) { "version_conflict_with_listed_subdep" }
        let(:lockfile_fixture_name) do
          "version_conflict_with_listed_subdep.lock"
        end
        let(:dependency_name) { "rspec-mocks" }
        let(:requirement_string) { ">= 0" }

        its([:version]) { is_expected.to eq(Gem::Version.new("3.6.0")) }
      end

      context "with a legacy Ruby which disallows the latest version" do
        let(:gemfile_fixture_name) { "legacy_ruby" }
        let(:lockfile_fixture_name) { "legacy_ruby.lock" }
        let(:dependency_name) { "public_suffix" }
        let(:requirement_string) { ">= 0" }

        # The latest version of public_suffix is 2.0.5, but requires Ruby 2.0.0
        # or greater.
        its([:version]) { is_expected.to eq(Gem::Version.new("1.4.6")) }

        context "when Bundler's compact index is down" do
          let(:versions_url) do
            "https://rubygems.org/api/v1/versions/public_suffix.json"
          end

          let(:rubygems_versions) do
            fixture("ruby", "rubygems_responses", "versions-public_suffix.json")
          end

          before do
            allow(Dependabot::SharedHelpers).
              to receive(:run_helper_subprocess).
              with({
                     command: Dependabot::Bundler::NativeHelpers.helper_path,
                     function: "resolve_version",
                     args: anything
                   }).
              and_return(
                {
                  version: "3.0.2",
                  ruby_version: "1.9.3",
                  fetcher: "Bundler::Fetcher::Dependency"
                }
              )

            stub_request(:get, versions_url).
              to_return(status: 200, body: rubygems_versions)
          end

          it { is_expected.to be_nil }

          context "and the dependency doesn't have a required Ruby version" do
            let(:rubygems_versions) do
              fixture(
                "ruby",
                "rubygems_responses",
                "versions-public_suffix.json"
              ).gsub(/"ruby_version": .*,/, '"ruby_version": null,')
            end

            its([:version]) { is_expected.to eq(Gem::Version.new("3.0.2")) }
          end
        end
      end

      context "with JRuby" do
        let(:gemfile_fixture_name) { "jruby" }
        let(:lockfile_fixture_name) { "jruby.lock" }
        let(:dependency_name) { "json" }
        let(:requirement_string) { ">= 0" }

        its([:version]) { is_expected.to be >= Gem::Version.new("1.4.6") }
      end

      context "when a gem has been yanked" do
        let(:gemfile_fixture_name) { "minor_version_specified" }
        let(:lockfile_fixture_name) { "yanked_gem.lock" }
        let(:requirement_string) { "~> 1.4" }

        context "and it's that gem that we're attempting to bump" do
          its([:version]) { is_expected.to eq(Gem::Version.new("1.18.0")) }
        end

        context "and it's another gem" do
          let(:dependency_name) { "statesman" }
          let(:requirement_string) { "~> 1.2" }
          its([:version]) { is_expected.to eq(Gem::Version.new("1.3.1")) }
        end
      end

      context "when unlocking a git dependency would cause errors" do
        let(:current_version) { "1.4.0" }
        let(:gemfile_fixture_name) { "git_source_circular" }
        let(:lockfile_fixture_name) { "git_source_circular.lock" }

        its([:version]) { is_expected.to eq(Gem::Version.new("2.1.0")) }
      end

      context "with a ruby exec command that fails" do
        let(:gemfile_fixture_name) { "exec_error" }
        let(:dependency_files) { [gemfile] }

        it "raises a DependencyFileNotEvaluatable error" do
          expect { subject }.
            to raise_error(Dependabot::DependencyFileNotEvaluatable)
        end
      end
    end

    context "when the Gem can't be found" do
      let(:gemfile_fixture_name) { "unavailable_gem" }
      let(:requirement_string) { "~> 1.4" }

      it "raises a DependencyFileNotResolvable error" do
        expect { subject }.
          to raise_error(Dependabot::DependencyFileNotResolvable)
      end
    end

    context "given an unreadable Gemfile" do
      let(:gemfile_fixture_name) { "includes_requires" }

      it "raises a useful error" do
        expect { subject }.
          to raise_error(Dependabot::DependencyFileNotEvaluatable) do |error|
            # Test that the temporary path isn't included in the error message
            expect(error.message).to_not include("dependabot_20")
          end
      end
    end

    context "given a path source" do
      let(:gemfile_fixture_name) { "path_source" }
      let(:lockfile_fixture_name) { "path_source.lock" }
      let(:requirement_string) { "~> 1.4.0" }

      context "without a downloaded gemspec" do
        let(:dependency_files) { [gemfile, lockfile] }

        it "raises a PathDependenciesNotReachable error" do
          expect { subject }.
            to raise_error(Dependabot::PathDependenciesNotReachable)
        end
      end
    end

    context "given a git source" do
      context "where updating would cause a circular dependency" do
        let(:gemfile_fixture_name) { "git_source_circular" }
        let(:lockfile_fixture_name) { "git_source_circular.lock" }

        let(:dependency_name) { "rubygems-circular-dependency" }
        let(:current_version) { "3c85f0bd8d6977b4dfda6a12acf93a282c4f5bf1" }
        let(:source) do
          {
            type: "git",
            url: "https://github.com/dependabot-fixtures/"\
                 "rubygems-circular-dependency",
            branch: "master",
            ref: "master"
          }
        end

        it { is_expected.to be_nil }
      end
    end

    context "with a gemspec and a Gemfile" do
      let(:dependency_files) { [gemfile, gemspec] }
      let(:gemfile_fixture_name) { "imports_gemspec" }
      let(:gemspec_fixture_name) { "small_example" }
      let(:unlock_requirement) { true }
      let(:current_version) { nil }
      let(:requirements) do
        [{
          file: "Gemfile",
          requirement: "~> 1.2.0",
          groups: [],
          source: nil
        }, {
          file: "example.gemspec",
          requirement: "~> 1.0",
          groups: [],
          source: nil
        }]
      end

      it "unlocks the latest version" do
        expect(resolver.latest_resolvable_version_details[:version]).
          to eq(Gem::Version.new("2.1.0"))
      end

      context "with an upper bound that is lower than the current req" do
        let(:latest_allowable_version) { "1.0.0" }
        let(:ignored_versions) { ["> 1.0.0"] }

        it { is_expected.to be_nil }
      end

      # TODO: https://github.com/dependabot/dependabot-core/issues/2364
      # context "with an implicit pre-release requirement" do
      #   let(:gemfile_fixture_name) { "imports_gemspec_implicit_pre" }
      #   let(:gemspec_fixture_name) { "implicit_pre" }
      #   let(:latest_allowable_version) { "6.0.3.1" }

      #   let(:unlock_requirement) { true }
      #   let(:current_version) { nil }
      #   let(:dependency_name) { "activesupport" }
      #   let(:requirements) do
      #     [{
      #       file: "example.gemspec",
      #       requirement: ">= 6.0",
      #       groups: [],
      #       source: nil
      #     }]
      #   end
      #   pending { is_expected.to be_nil }
      # end

      context "when an old required ruby is specified in the gemspec" do
        let(:gemspec_fixture_name) { "old_required_ruby" }
        let(:dependency_name) { "statesman" }
        let(:latest_allowable_version) { "7.2.0" }

        it "takes the minimum ruby version into account" do
          expect(resolver.latest_resolvable_version_details[:version]).
            to eq(Gem::Version.new("2.0.1"))
        end

        context "that isn't satisfied by the dependencies" do
          let(:gemfile_fixture_name) { "imports_gemspec_version_clash" }
          let(:current_version) { "3.0.1" }

          it "ignores the minimum ruby version in the gemspec" do
            expect(resolver.latest_resolvable_version_details[:version]).
              to eq(Gem::Version.new("7.2.0"))
          end
        end
      end
    end
  end
end
