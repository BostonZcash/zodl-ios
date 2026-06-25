# frozen_string_literal: true

require "zodl/version"
require "zodl/variants"
require "zodl/build_number"

module Zodl
  # Pure reconciliation of declared intent against gathered facts. No I/O — the
  # Fastfile gathers facts and passes them in as `ctx`, so this is fully testable.
  class Preflight
    Report = Struct.new(:errors, :warnings) do
      def ok?
        errors.empty?
      end
    end

    def self.check(ctx)
      errors = []
      warnings = []

      return Report.new(["unknown variant '#{ctx.variant}'"], warnings) unless Zodl::Variants.valid?(ctx.variant)

      errors << "version '#{ctx.requested_version}' is not in X.Y.Z form" unless Zodl::Version.valid?(ctx.requested_version)

      if ctx.branch_version && ctx.requested_version != ctx.branch_version
        errors << "version #{ctx.requested_version} does not match release branch version #{ctx.branch_version}"
      end

      if ctx.project_version && ctx.requested_version != ctx.project_version
        errors << "version #{ctx.requested_version} does not match project MARKETING_VERSION #{ctx.project_version}"
      end

      bn = Zodl::BuildNumber.validate(requested: ctx.requested_build, latest: ctx.latest_build)
      errors << bn.error if bn.error
      warnings << bn.warning if bn.warning

      errors << "ref is not on origin — push it before releasing" unless ctx.ref_on_origin
      errors << "PartnerKeys.plist is missing or invalid" unless ctx.partner_keys_ok
      errors << "Xcode version does not match .xcode-version" unless ctx.xcode_ok
      errors << "no distribution signing identity found in the keychain" unless ctx.signing_identity_ok

      warnings << "working tree has uncommitted changes — they are NOT included in this build" if ctx.dirty_tree

      Report.new(errors, warnings)
    end
  end
end
