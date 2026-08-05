import 'activity.dart';
import 'activity_classifier.dart';
import 'calibration_params.dart';
import 'sensor_sample.dart';
import 'step_detector.dart';

/// Steps confirmed by one sample, and what the user was doing at the time.
class PipelineEvent {
  const PipelineEvent(this.stepTimestampsNs, this.activity);

  final List<int> stepTimestampsNs;
  final Activity activity;

  bool get hasSteps => stepTimestampsNs.isNotEmpty;
}

/// Runs the step detector and the activity classifier over one sample stream.
///
/// Exists so the band-pass is computed once and both consumers see exactly the
/// same filtered signal. Running two independent filter chains would let them
/// disagree about the same instant.
class MotionPipeline {
  MotionPipeline({
    CalibrationParams params = CalibrationParams.factory,
    ActivityParams activityParams = ActivityParams.factory,
    double sampleRateHz = 50.0,
  })  : detector = StepDetector(params: params, sampleRateHz: sampleRateHz),
        classifier = ActivityClassifier(params: activityParams);

  final StepDetector detector;
  final ActivityClassifier classifier;

  Activity get activity => classifier.current;
  int get totalSteps => detector.totalSteps;

  set params(CalibrationParams p) => detector.params = p;
  set activityParams(ActivityParams p) => classifier.params = p;

  /// Barometer readings arrive on their own schedule, far slower than motion.
  void addPressure(int tNs, double hPa) => classifier.addPressure(tNs, hPa);

  PipelineEvent addSample(SensorSample s) {
    final steps = detector.addSample(s);
    final activity = classifier.update(
      tNs: s.tNs,
      rawMagnitude: detector.lastRawMagnitude,
      filteredMagnitude: detector.lastFilteredMagnitude,
      gyroMagnitude: s.gyroMagnitude,
      hasGyro: s.hasGyro,
      stepsEmitted: steps.length,
    );
    return PipelineEvent(steps, activity);
  }

  void reset() {
    detector.reset();
    classifier.reset();
  }

  /// Replays a recorded session and returns the step count per activity.
  ///
  /// Used by the calibration screens to show what a candidate parameter set
  /// would have produced, through the same code that runs live.
  static Map<Activity, int> replay(
    List<SensorSample> samples, {
    List<PressureSample> pressure = const [],
    CalibrationParams params = CalibrationParams.factory,
    ActivityParams activityParams = ActivityParams.factory,
  }) {
    final pipeline = MotionPipeline(
      params: params,
      activityParams: activityParams,
    );
    final counts = <Activity, int>{};

    // Pressure and motion are merged by timestamp so replay sees them in the
    // same order the live pipeline did.
    var p = 0;
    for (final s in samples) {
      while (p < pressure.length && pressure[p].tNs <= s.tNs) {
        pipeline.addPressure(pressure[p].tNs, pressure[p].hPa);
        p++;
      }
      final event = pipeline.addSample(s);
      if (event.hasSteps) {
        counts[event.activity] =
            (counts[event.activity] ?? 0) + event.stepTimestampsNs.length;
      }
    }
    return counts;
  }

  /// Total steps from a replay, ignoring how they were earned.
  static int replayTotal(
    List<SensorSample> samples, {
    List<PressureSample> pressure = const [],
    CalibrationParams params = CalibrationParams.factory,
    ActivityParams activityParams = ActivityParams.factory,
  }) =>
      replay(
        samples,
        pressure: pressure,
        params: params,
        activityParams: activityParams,
      ).values.fold(0, (a, b) => a + b);
}
