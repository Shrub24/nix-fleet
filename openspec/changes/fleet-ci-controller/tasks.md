# Tasks

Nothing here starts before the organisation move. Spikes decide whether the later
phases happen; implementation decisions stay open until they are answered.

## 0. Spikes (each ends in a recorded answer)

- [ ] 0.1 Admission: against a fake-GitHub test, show `prApproval` held by default
      with a trusted automation identity. Cover: same-repository head from a
      non-trusted author, a later push by a human to a trusted PR, an App-sent
      label or reopen on a human-pushed head, approval persistence, and a polled
      change with no actor. State the smallest change and whether it is
      upstreamable; the parser lacks author id and type today
- [ ] 0.2 Branch-write enforcement: on a personal repository, a ruleset on
      `automation/**` where only the App (`Integration` bypass) can create or update,
      and a human push is refused; record what the plan and repository type allow
- [ ] 0.3 Checks: the aggregate check name, a ruleset pinning it by integration id,
      and that an ordinary branch push cannot bypass admission (instance
      `build_branches` default)
- [ ] 0.4 Reuse and publication: PR build then merge to `main` with an identical
      tree; confirm reuse, that the default-branch effect runs (PR effects off, so
      `effects_started` is unset), that it can be restarted or scheduled without a
      new push, and what an upload failure (three attempts) leaves behind
- [ ] 0.5 Pins: create the rolling pin from a default-branch effect and confirm the
      presence refusal on an unpublished root
- [ ] 0.6 Host and niks3: choose the host, size it for the largest consumer
      evaluation, confirm niks3 against the module requirement
- [ ] 0.7 Endpoint: where the webhook is exposed without a general ingress, and the
      failure mode while the controller is down (undelivered webhooks are not replayed)
- [ ] 0.8 Run one artefact repository (Pi-Bolt.nix) end to end beside `fleet-build`
      and compare cache population and wall time

## 1. Fleet aspect

- [ ] 1.1 A NixOS aspect enabling the controller, builders derived from
      `lib.buildProfile`, secrets bound by the consumer
- [ ] 1.2 A named failure for each missing binding
- [ ] 1.3 A check for the one behaviour evaluation cannot falsify: the rendered
      builder set equals the profile

## 2. Consumer contract

- [ ] 2.1 What a consumer declares (selection as flake outputs) and no longer holds
- [ ] 2.2 Document the admission policy and the approve-to-run versus merge split
- [ ] 2.3 Consumer change recorded: drop `configurationRevision` where it exists

## 3. Replace the lifecycle

- [ ] 3.1 Required controller check plus auto-merge for automation pull requests on
      one repository
- [ ] 3.2 Default-branch effect: publish retention root, pin, verify
- [ ] 3.3 Retire the candidate path for that repository

## 4. Retire the per-run path

- [ ] 4.1 Remove the coordinator artifact, installer, per-workflow claims and
      per-repository builder key once no consumer calls `build-push-cache.yml`
- [ ] 4.2 Record the invariants each removed check protected

## 5. Revisit after the controller operates

- [ ] 5.1 Native `onSchedule` producer with an explicit empty secret map for the
      execution effect, and a separate effect for publication
