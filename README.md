# Step Counter

An Android step counter that derives steps from raw accelerometer and gyroscope
data rather than trusting the OS pedometer, and that improves its own detection
from the data it collects.

## Why not just use the built-in step sensor

Android's `TYPE_STEP_COUNTER` is well tuned but opaque and unchangeable. This app
runs its own detector so the algorithm can be inspected, tested, and calibrated
to how *you* walk and where you carry your phone — and uses the hardware sensor
only as a free source of ground truth to grade itself against.

## How detection works

Sampling runs at 50 Hz, comfortably inside the 200 Hz cap Android 12+ applies
without `HIGH_SAMPLING_RATE_SENSORS`.

```
accel magnitude → band-pass 0.5–3 Hz → smooth → adaptive threshold
   → peak/valley pairing → temporal gate → regularity gate → gyro gate
```

1. **Magnitude**, `√(x²+y²+z²)`, not any single axis — so the detector is
   orientation-independent and works in a pocket, a bag, or a hand without
   knowing the device's pose.
2. **Band-pass 0.5–3 Hz** (2nd-order Butterworth). Human gait lives in this
   band; this strips the gravity DC term and high-frequency handling noise in
   one stage.
3. **Absolute motion floor.** The band-passed signal's standard deviation must
   exceed `minMotionSigma` before anything is counted. This has to come first,
   because the adaptive threshold below is derived from the signal's own
   deviation and therefore *shrinks along with the noise it is meant to
   reject* — on a near-still phone it collapses toward zero and fires on desk
   vibration. Measured over the detector's window: a still or lightly disturbed
   phone sits at 0.13–0.33, ordinary walking at 1.28, jogging at 1.89.
4. **Adaptive threshold** `T = mean + k·σ` over a 2.5 s window, so the same
   parameters cover a slow shuffle and a jog. Note what it cannot do: raising
   `k` does not reject small movement, because `k` multiplies a deviation that
   is itself small. That is `minMotionSigma`'s job.
5. **Peak/valley pairing** with a minimum valley-to-peak amplitude.
6. **Temporal gate** rejects intervals under 250 ms — faster than that is a
   bounce within one footfall, not a second step.
7. **Regularity gate** requires four consecutive rhythmic candidates before
   counting any of them. This is the primary false-positive defence: gesturing
   or pulling the phone out of a pocket produces one or two peaks, never four
   evenly spaced ones. A continuous walk pays this warm-up only once.
8. **Gyroscope gate** rejects motion with no rotation — road vibration in a
   vehicle produces gait-like acceleration peaks with almost no rotational
   energy, and it is the largest source of phantom steps in naive pedometers.

The gyroscope is measured as a **raw magnitude level, not band-passed**.
Rotation about one axis makes `|ω|` a rectified sine at twice the gait
frequency, so band-passing it attenuates it more the faster you walk — which
rejected jogging while accepting a stroll. Mean raw level separates the cases
cleanly: ~0.004 rad/s in a vehicle, ~0.2–0.5 walking, ~10 shaking the phone.

### What it cannot do

Sustained motion that is rhythmic *at gait frequency and gait amplitude* is not
separable from walking by these means. Measured over the detector's window,
sustained non-gait motion reaches a deviation of 0.52 while genuinely damped
walking — a phone loose in a bag — sits at 0.57. They overlap, and no constant
threshold divides them.

An autocorrelation-based periodicity gate was tried and removed: it did suppress
irregular motion, but it also cost a quarter of every run, and its effect turned
out to come from instability in the cadence estimate rather than from measuring
periodicity as intended. A gate whose mechanism is not the one claimed is worse
than no gate.

The tool that does address this case is per-user calibration against the
hardware pedometer, which supplies a real error signal instead of a guess.

## Activity detection

Steps are attributed to walking, running, stairs up, or stairs down, and the
chart colours each day's bar by how it was earned. Still and vehicle are also
recognised but never contribute steps.

**Walking vs running** turns on the flight phase. Cadence alone cannot decide it
— a brisk walk reaches 140 spm and overlaps a slow jog — but running lifts both
feet off the ground, so `|a|` dips toward freefall in a way walking never does.
Cadence is required, then either that dip or a hard impact confirms it.

**Stairs need the barometer**, and the reason is worth stating because the
intuition runs the other way. Stair *ascent* produces **lower** peak
acceleration than level walking — the body is lifted rather than struck against
the ground — while *descent* produces higher impact than either. Amplitude
therefore points the wrong way half the time, and an accelerometer-only stair
classifier confuses ascent with a slow walk and descent with running.

Barometric altitude gives direction of travel unambiguously: ~8.3 m per hPa, so
a 3 m flight of stairs is roughly ten times sensor noise. Vertical speed comes
from a least-squares fit over a six-second window rather than a difference
between two readings — barometer noise is about 0.25 m, which would swamp a
two-point estimate of a 0.2 m/s climb. Sustained motion is required before
stairs are claimed, so a door opening cannot register as a flight, and weather
drift is four orders of magnitude too slow to matter.

Climbing in a lift is not stairs: no steps, no attribution. Devices without a
barometer never claim stairs at all, and Settings says so rather than silently
never showing the category.

## Calibration

Seven interpretable parameters are tuned by coordinate descent — deliberately
not a learned model, because a handful of named numbers can be clamped to
physiological ranges, shown to the user, diffed, and reverted.

**Automatic** (toggleable). While you walk, the service records short windows of
raw motion and labels them with the hardware pedometer's count for that exact
window. Windows are only finalised after you have genuinely stopped for twenty
seconds, since `TYPE_STEP_COUNTER` reports with up to ten seconds of latency and
a label read mid-walk would be wrong.

**Test & Recalibrate.** Walk a known number of steps, type in what you counted,
and the app replays the recording — plus every previously stored session —
through the real detector. You also declare what you were doing, which labels
the recording so the activity thresholds can be tuned too: a slow climber whose
0.05 m/s ascent falls below the default 0.08 m/s floor is exactly the case this
fixes.

Activity thresholds are optimised the same way as the step parameters, scored on
the share of steps filed under the declared activity rather than on step-count
error, with the same holdout validation.

Guardrails on both paths:

- the search runs from the current parameters *and* from the factory ones,
  keeping whichever wins. Coordinate descent moves one parameter at a time and
  cannot escape a corner where two are jointly wrong — with both the motion and
  amplitude floors too strict, relaxing either alone still detects nothing, so
  no single move improves and the search would sit there forever;
- new parameters must beat the **old** parameters on sessions the search never
  saw (every third session is held back, index-based so recalibrating twice
  gives the same answer);
- the search must have actually moved and the baseline error must be non-zero,
  otherwise an already-perfect baseline satisfies `0 ≤ 0 × 0.98` and the app
  adopts an identical set while reporting an improvement;
- automatic adoption additionally needs six labelled windows;
- improvement must exceed 2% relative, since churning for noise makes the app
  feel unpredictable.

Every adopted set is stored as a version, so a bad calibration is always
traceable and reversible.

## Architecture

| | |
|---|---|
| `android/.../StepSensorService.kt` | Foreground service: sensors, live detection, minute buckets |
| `android/.../StepDetectorNative.kt` | Kotlin detector (live counting path) |
| `android/.../ActivityClassifierNative.kt` | Kotlin activity classifier |
| `lib/detection/` | Dart detector and classifier (replay path) + optimisers |
| `lib/data/` | drift schema, repository |
| `lib/ui/` | Screens |

Counting runs in a **native foreground service** because a step counter that
stops when the screen turns off is useless, and Dart cannot hold sensor streams
in that state. Its notification uses `IMPORTANCE_MIN` — silent and collapsed
into the low-priority section of the shade, which is as quiet as Android permits
for a foreground service. It cannot be hidden entirely.

The service cannot write to the app's database, because it counts in a process
that outlives the UI. It accumulates into its own storage and Dart drains it
destructively — the native copy is dropped only once Dart has the buckets in
hand to commit.

### Keeping two detectors in agreement

Kotlin counts live; Dart replays during calibration. If they drift, every
before/after number describes an algorithm that is not the one counting your
steps. Golden fixtures in `android/app/src/test/resources/goldens/` pin both
sides to the same expected counts:

- `test/golden_fixtures_test.dart` asserts them in Dart
- `DetectionGoldenTest.kt` asserts them on the JVM in CI

Regenerate deliberately, and review the diff in expected counts:

```
dart tool/generate_goldens.dart
```

## Permissions

| Permission | Why | If denied |
|---|---|---|
| `ACTIVITY_RECOGNITION` | Hardware pedometer as a calibration reference | Automatic calibration falls back to manual sessions |
| _(none)_ | Barometer needs no permission | Stairs unavailable if the device lacks one |
| `FOREGROUND_SERVICE(_HEALTH)` | Counting with the screen off | Required |
| `POST_NOTIFICATIONS` | The service's own notification | Service still runs |
| `RECEIVE_BOOT_COMPLETED` | Resume counting after a reboot | Counting stops until the app is opened |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Offered in Settings | Some OEM skins kill the service |

The displayed count **always** comes from our own detector. The hardware sensor
is only ever a grading signal.

## Building

```
flutter pub get
dart run build_runner build
flutter test
flutter build apk --release
```

Release builds are signed with the debug key on purpose: this app is distributed
as a sideloaded APK from CI, so no keystore secrets are needed. The `Build APK`
workflow runs analysis, Dart tests, the release build, and the Kotlin golden
tests, then uploads the APK as an artifact.

## Development notes

- The detector is deterministic and driven only by sample timestamps — no wall
  clock, no randomness. Calibration replays depend on it.
- Recorded samples are buffered as doubles. Sensor timestamps are nanoseconds
  since boot; after a few days of uptime that is ~4×10⁸ ms, where float32
  resolves to ~32 ms — coarser than the 20 ms sampling period. Narrowing to
  float happens only after times are made relative to the first sample.
- Steps are stored in minute buckets keyed by activity, so one minute can hold
  both the walk to a staircase and the climb. ~500k rows a year, which SQLite
  does not notice.
- Schema v2 added the activity dimension to the step table's primary key.
  SQLite cannot alter a primary key in place, so the migration rebuilds the
  table; `test/migration_test.dart` exercises it against a real v1 database.
  Pre-existing rows are labelled `unknown` rather than guessed at as walking.
