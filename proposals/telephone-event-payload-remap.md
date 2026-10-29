# Draft: explicit telephone-event payload preference

**Prototype for upstream review, not production validated.** Published in the
[feature/dtmf-payload-remap branch](https://github.com/descartin/rtpengine/tree/feature/dtmf-payload-remap)
of the public `descartin/rtpengine` fork. No upstream issue, pull request, or
maintainer message has been published. Full compilation and runtime tests remain
blocked/not run as documented below.

## Intended PR title

Add an outgoing telephone-event payload-type preference to NG offers

## Draft PR body

### Motivation

Some peers require a specific dynamic RTP payload type for telephone-event,
for example 101 rather than 96. This proposal concerns RFC 4733/RFC 2833 event
packets, not audio-tone detection or tone generation.

### Approach

Add `codec: {"telephone-event-payload": 101}` to an NG offer. Restrict the first
version to one existing telephone-event codec and a compatible same-clock-rate
input codec. Reindex a copied codec in the outgoing leg before handler setup and
before the offered-codec snapshots are saved. Leave the original leg unchanged.
Existing codec matching and DTMF handlers perform the RTP PT translation and
reverse answer construction. There is no new RTP mutation or DSP implementation.

The preference must not overwrite another codec. Collision, ambiguity, and an
incompatible asymmetric-mode offer log a warning and leave this preference
unapplied. This is deliberately an optional preference, not a mandatory gateway
policy. Callers must inspect the returned SDP. Invalid input types/ranges and
non-offer use return an NG error.

### Trade-offs / questions for maintainers

- Is an optional warning-and-ignore preference appropriate, or should a future
  mandatory variant fail the offer transaction on collision/ambiguity?
- Is the codec dictionary the right API? This first version deliberately has no
  flags-list alias; it requires a native integer rather than permissive parsing.
- Should a later version select a specific clock rate when several event codecs
  are present? This version refuses that ambiguity.
- The existing DTMF path rebuilds RTP, participates in SSRC/sequence/RTCP
  translation, and may activate the audio player depending on configuration.
  Tests explicitly request `audio-player=off`. No new all-audio DSP is requested
  by this flag, but zero extra CPU cost and unchanged RTP headers are not claimed.
- `allow-asymmetric-codecs` must not be used on either offer or answer. The offer
  combination is guarded; independently enabling it in an answer is an unsupported
  combination, not silently corrected by persistent mapping metadata.
- Interaction with static/reused codecs, mixed codec-manipulation policies,
  call restoration, SRTP, and forking needs integration coverage before merge.

### Validation status

The C prototype and daemon tests are review material. Full compilation and daemon
execution were blocked in this container; see the reproducible evidence below.
Do not treat test source or static inspection as successful RTP verification.

## Exact source targets

- master baseline: `64c3bc104e3d1c232186bba3329c29c2d90d30f5`
- requested backport: tag `mr26.0.1.26`, commit
  `0744060fe434fb1ab079fa4baeac20d67d94a2cc`

## Build/test evidence

Environment: Debian GNU/Linux 13 (trixie), uid 1000; no sudo or container runtime
was found. `docs/compiling_and_installing.md`, `t/Makefile`, and the upstream
unit-tests workflow were read. No AGENTS.md or repository skills were present.

- `make -C daemon -j2`: blocked before compiling any source by
  `Error: Required package 'glib-2.0' not found`.
- `apt-get update`: exit 100, permission denied reading
  `/etc/apt/apt.conf.d/80-applied-apt-retries`; package-list `partial` directory
  absent. No packages installed.
- One supported escalated attempt failed during environment startup before apt
  executed (`bwrap` read-only filesystem error). No retry or workaround attempted.
- `PERL5LIB=perl perl -c t/auto-daemon-tests-dtmf-payload-remap.pl`: blocked
  by missing `Socket6.pm` required by `NGCP::Rtpengine::Test`. A separate grammar-only
  check with NGCP imports removed passed; this does **not** validate loading the
  real harness or executing the tests.
- `git diff --check`: passed (whitespace only).
- Full `make check`, upstream `make asan-check`, and live RTP/SRTP/kernel tests:
  **not run**.

On a suitably provisioned upstream build environment run:

```sh
make -C t daemon-tests-dtmf-payload-remap
make check
make asan-check
```

Before merge also verify blocked/logged DTMF, malformed RTP, RTP extensions/CSRC/
padding, SRTP in both directions, two divergent sinks, event rejection and
re-offers (including reversed dialogue direction), audio-player modes, packet
loss/reordering, and no-transcoding-build rejection. Existing DTMF, asymmetric,
codec-prefs, RTCP, RTP-extension and fanout suites are relevant regressions.

## Backport assessment

A direct `git apply --check` of the master changes onto a clean detached
`mr26.0.1.26` worktree **failed**. There is no verified backport branch or patch.
The failure is substantive, not merely an offset:

- `daemon/call_flags.c` and `include/call_flags.h` do not exist in that tag;
  parsing/flags are in `daemon/call_interfaces.c` and `include/call_interfaces.h`.
- The old `call_ng_codec_flags` callback returns `void`; master returns
  `const char *` to propagate a parse error. Simply moving the new parser code
  would not compile or preserve invalid-input rejection. A backport needs an
  explicit compatible error path, or a separately reviewed parser prerequisite.
- `codecs_offer` uses `media` / `other_media` rather than `receiver` / `sender`;
  the insertion point must be adapted while retaining directionality.
- `t/Makefile` has different aggregate-target context; wire the focused test into
  the old test suite manually.

The codec-store helper and existing event translation machinery have equivalent
building blocks in the exact tag, so a targeted manual backport is plausible.
It is **not** currently a clean cherry-pick, compiled backport, or supported
release guarantee. Master acceptance also does not imply maintainer approval
for adding a feature to the stable branch. The next backport step is to settle
parse-error semantics with maintainers and adapt those four locations, then run
the same negotiation/RTP/regression matrix against the exact tag. No changes
were left in the detached backport-inspection worktree.

A later header-only optimization is a separate change: master has per-sink input
packet isolation in `daemon/media_socket.c` that mr26.0.1.26 lacks. Directly
mutating a shared RTP header in the old branch would risk corrupting another
sink. Such an optimization would need owned output buffers or an explicitly
reviewed isolation backport, and must preserve DTMF logging/blocking and SRTP
ordering. This prototype intentionally avoids that new risk by using the
existing event handler.
