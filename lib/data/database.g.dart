// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $StepMinutesTable extends StepMinutes
    with TableInfo<$StepMinutesTable, StepMinute> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StepMinutesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _minuteEpochMeta = const VerificationMeta(
    'minuteEpoch',
  );
  @override
  late final GeneratedColumn<int> minuteEpoch = GeneratedColumn<int>(
    'minute_epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stepsMeta = const VerificationMeta('steps');
  @override
  late final GeneratedColumn<int> steps = GeneratedColumn<int>(
    'steps',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [minuteEpoch, steps];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'step_minutes';
  @override
  VerificationContext validateIntegrity(
    Insertable<StepMinute> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('minute_epoch')) {
      context.handle(
        _minuteEpochMeta,
        minuteEpoch.isAcceptableOrUnknown(
          data['minute_epoch']!,
          _minuteEpochMeta,
        ),
      );
    }
    if (data.containsKey('steps')) {
      context.handle(
        _stepsMeta,
        steps.isAcceptableOrUnknown(data['steps']!, _stepsMeta),
      );
    } else if (isInserting) {
      context.missing(_stepsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {minuteEpoch};
  @override
  StepMinute map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StepMinute(
      minuteEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}minute_epoch'],
      )!,
      steps: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}steps'],
      )!,
    );
  }

  @override
  $StepMinutesTable createAlias(String alias) {
    return $StepMinutesTable(attachedDatabase, alias);
  }
}

class StepMinute extends DataClass implements Insertable<StepMinute> {
  /// Minutes since the Unix epoch, in local wall-clock terms.
  final int minuteEpoch;
  final int steps;
  const StepMinute({required this.minuteEpoch, required this.steps});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['minute_epoch'] = Variable<int>(minuteEpoch);
    map['steps'] = Variable<int>(steps);
    return map;
  }

  StepMinutesCompanion toCompanion(bool nullToAbsent) {
    return StepMinutesCompanion(
      minuteEpoch: Value(minuteEpoch),
      steps: Value(steps),
    );
  }

  factory StepMinute.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StepMinute(
      minuteEpoch: serializer.fromJson<int>(json['minuteEpoch']),
      steps: serializer.fromJson<int>(json['steps']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'minuteEpoch': serializer.toJson<int>(minuteEpoch),
      'steps': serializer.toJson<int>(steps),
    };
  }

  StepMinute copyWith({int? minuteEpoch, int? steps}) => StepMinute(
    minuteEpoch: minuteEpoch ?? this.minuteEpoch,
    steps: steps ?? this.steps,
  );
  StepMinute copyWithCompanion(StepMinutesCompanion data) {
    return StepMinute(
      minuteEpoch: data.minuteEpoch.present
          ? data.minuteEpoch.value
          : this.minuteEpoch,
      steps: data.steps.present ? data.steps.value : this.steps,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StepMinute(')
          ..write('minuteEpoch: $minuteEpoch, ')
          ..write('steps: $steps')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(minuteEpoch, steps);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StepMinute &&
          other.minuteEpoch == this.minuteEpoch &&
          other.steps == this.steps);
}

class StepMinutesCompanion extends UpdateCompanion<StepMinute> {
  final Value<int> minuteEpoch;
  final Value<int> steps;
  const StepMinutesCompanion({
    this.minuteEpoch = const Value.absent(),
    this.steps = const Value.absent(),
  });
  StepMinutesCompanion.insert({
    this.minuteEpoch = const Value.absent(),
    required int steps,
  }) : steps = Value(steps);
  static Insertable<StepMinute> custom({
    Expression<int>? minuteEpoch,
    Expression<int>? steps,
  }) {
    return RawValuesInsertable({
      if (minuteEpoch != null) 'minute_epoch': minuteEpoch,
      if (steps != null) 'steps': steps,
    });
  }

  StepMinutesCompanion copyWith({Value<int>? minuteEpoch, Value<int>? steps}) {
    return StepMinutesCompanion(
      minuteEpoch: minuteEpoch ?? this.minuteEpoch,
      steps: steps ?? this.steps,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (minuteEpoch.present) {
      map['minute_epoch'] = Variable<int>(minuteEpoch.value);
    }
    if (steps.present) {
      map['steps'] = Variable<int>(steps.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StepMinutesCompanion(')
          ..write('minuteEpoch: $minuteEpoch, ')
          ..write('steps: $steps')
          ..write(')'))
        .toString();
  }
}

class $CalibrationSessionsTable extends CalibrationSessions
    with TableInfo<$CalibrationSessionsTable, CalibrationSession> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalibrationSessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _recordedAtMeta = const VerificationMeta(
    'recordedAt',
  );
  @override
  late final GeneratedColumn<int> recordedAt = GeneratedColumn<int>(
    'recorded_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actualStepsMeta = const VerificationMeta(
    'actualSteps',
  );
  @override
  late final GeneratedColumn<int> actualSteps = GeneratedColumn<int>(
    'actual_steps',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _detectedStepsMeta = const VerificationMeta(
    'detectedSteps',
  );
  @override
  late final GeneratedColumn<int> detectedSteps = GeneratedColumn<int>(
    'detected_steps',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 16,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _samplesMeta = const VerificationMeta(
    'samples',
  );
  @override
  late final GeneratedColumn<Uint8List> samples = GeneratedColumn<Uint8List>(
    'samples',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    recordedAt,
    durationMs,
    actualSteps,
    detectedSteps,
    source,
    samples,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calibration_sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalibrationSession> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('recorded_at')) {
      context.handle(
        _recordedAtMeta,
        recordedAt.isAcceptableOrUnknown(data['recorded_at']!, _recordedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_recordedAtMeta);
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    } else if (isInserting) {
      context.missing(_durationMsMeta);
    }
    if (data.containsKey('actual_steps')) {
      context.handle(
        _actualStepsMeta,
        actualSteps.isAcceptableOrUnknown(
          data['actual_steps']!,
          _actualStepsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_actualStepsMeta);
    }
    if (data.containsKey('detected_steps')) {
      context.handle(
        _detectedStepsMeta,
        detectedSteps.isAcceptableOrUnknown(
          data['detected_steps']!,
          _detectedStepsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_detectedStepsMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('samples')) {
      context.handle(
        _samplesMeta,
        samples.isAcceptableOrUnknown(data['samples']!, _samplesMeta),
      );
    } else if (isInserting) {
      context.missing(_samplesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CalibrationSession map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalibrationSession(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      recordedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}recorded_at'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      )!,
      actualSteps: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}actual_steps'],
      )!,
      detectedSteps: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}detected_steps'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      samples: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}samples'],
      )!,
    );
  }

  @override
  $CalibrationSessionsTable createAlias(String alias) {
    return $CalibrationSessionsTable(attachedDatabase, alias);
  }
}

class CalibrationSession extends DataClass
    implements Insertable<CalibrationSession> {
  final int id;
  final int recordedAt;
  final int durationMs;

  /// Ground truth. From the user in the manual flow, from the hardware
  /// pedometer in the automatic one.
  final int actualSteps;

  /// What the detector counted at the time of recording, kept for display.
  final int detectedSteps;

  /// 'manual' or 'automatic'.
  final String source;

  /// Packed float32 samples, the same layout SensorSample.pack produces.
  final Uint8List samples;
  const CalibrationSession({
    required this.id,
    required this.recordedAt,
    required this.durationMs,
    required this.actualSteps,
    required this.detectedSteps,
    required this.source,
    required this.samples,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['recorded_at'] = Variable<int>(recordedAt);
    map['duration_ms'] = Variable<int>(durationMs);
    map['actual_steps'] = Variable<int>(actualSteps);
    map['detected_steps'] = Variable<int>(detectedSteps);
    map['source'] = Variable<String>(source);
    map['samples'] = Variable<Uint8List>(samples);
    return map;
  }

  CalibrationSessionsCompanion toCompanion(bool nullToAbsent) {
    return CalibrationSessionsCompanion(
      id: Value(id),
      recordedAt: Value(recordedAt),
      durationMs: Value(durationMs),
      actualSteps: Value(actualSteps),
      detectedSteps: Value(detectedSteps),
      source: Value(source),
      samples: Value(samples),
    );
  }

  factory CalibrationSession.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalibrationSession(
      id: serializer.fromJson<int>(json['id']),
      recordedAt: serializer.fromJson<int>(json['recordedAt']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      actualSteps: serializer.fromJson<int>(json['actualSteps']),
      detectedSteps: serializer.fromJson<int>(json['detectedSteps']),
      source: serializer.fromJson<String>(json['source']),
      samples: serializer.fromJson<Uint8List>(json['samples']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'recordedAt': serializer.toJson<int>(recordedAt),
      'durationMs': serializer.toJson<int>(durationMs),
      'actualSteps': serializer.toJson<int>(actualSteps),
      'detectedSteps': serializer.toJson<int>(detectedSteps),
      'source': serializer.toJson<String>(source),
      'samples': serializer.toJson<Uint8List>(samples),
    };
  }

  CalibrationSession copyWith({
    int? id,
    int? recordedAt,
    int? durationMs,
    int? actualSteps,
    int? detectedSteps,
    String? source,
    Uint8List? samples,
  }) => CalibrationSession(
    id: id ?? this.id,
    recordedAt: recordedAt ?? this.recordedAt,
    durationMs: durationMs ?? this.durationMs,
    actualSteps: actualSteps ?? this.actualSteps,
    detectedSteps: detectedSteps ?? this.detectedSteps,
    source: source ?? this.source,
    samples: samples ?? this.samples,
  );
  CalibrationSession copyWithCompanion(CalibrationSessionsCompanion data) {
    return CalibrationSession(
      id: data.id.present ? data.id.value : this.id,
      recordedAt: data.recordedAt.present
          ? data.recordedAt.value
          : this.recordedAt,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      actualSteps: data.actualSteps.present
          ? data.actualSteps.value
          : this.actualSteps,
      detectedSteps: data.detectedSteps.present
          ? data.detectedSteps.value
          : this.detectedSteps,
      source: data.source.present ? data.source.value : this.source,
      samples: data.samples.present ? data.samples.value : this.samples,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalibrationSession(')
          ..write('id: $id, ')
          ..write('recordedAt: $recordedAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('actualSteps: $actualSteps, ')
          ..write('detectedSteps: $detectedSteps, ')
          ..write('source: $source, ')
          ..write('samples: $samples')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    recordedAt,
    durationMs,
    actualSteps,
    detectedSteps,
    source,
    $driftBlobEquality.hash(samples),
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalibrationSession &&
          other.id == this.id &&
          other.recordedAt == this.recordedAt &&
          other.durationMs == this.durationMs &&
          other.actualSteps == this.actualSteps &&
          other.detectedSteps == this.detectedSteps &&
          other.source == this.source &&
          $driftBlobEquality.equals(other.samples, this.samples));
}

class CalibrationSessionsCompanion extends UpdateCompanion<CalibrationSession> {
  final Value<int> id;
  final Value<int> recordedAt;
  final Value<int> durationMs;
  final Value<int> actualSteps;
  final Value<int> detectedSteps;
  final Value<String> source;
  final Value<Uint8List> samples;
  const CalibrationSessionsCompanion({
    this.id = const Value.absent(),
    this.recordedAt = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.actualSteps = const Value.absent(),
    this.detectedSteps = const Value.absent(),
    this.source = const Value.absent(),
    this.samples = const Value.absent(),
  });
  CalibrationSessionsCompanion.insert({
    this.id = const Value.absent(),
    required int recordedAt,
    required int durationMs,
    required int actualSteps,
    required int detectedSteps,
    required String source,
    required Uint8List samples,
  }) : recordedAt = Value(recordedAt),
       durationMs = Value(durationMs),
       actualSteps = Value(actualSteps),
       detectedSteps = Value(detectedSteps),
       source = Value(source),
       samples = Value(samples);
  static Insertable<CalibrationSession> custom({
    Expression<int>? id,
    Expression<int>? recordedAt,
    Expression<int>? durationMs,
    Expression<int>? actualSteps,
    Expression<int>? detectedSteps,
    Expression<String>? source,
    Expression<Uint8List>? samples,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (recordedAt != null) 'recorded_at': recordedAt,
      if (durationMs != null) 'duration_ms': durationMs,
      if (actualSteps != null) 'actual_steps': actualSteps,
      if (detectedSteps != null) 'detected_steps': detectedSteps,
      if (source != null) 'source': source,
      if (samples != null) 'samples': samples,
    });
  }

  CalibrationSessionsCompanion copyWith({
    Value<int>? id,
    Value<int>? recordedAt,
    Value<int>? durationMs,
    Value<int>? actualSteps,
    Value<int>? detectedSteps,
    Value<String>? source,
    Value<Uint8List>? samples,
  }) {
    return CalibrationSessionsCompanion(
      id: id ?? this.id,
      recordedAt: recordedAt ?? this.recordedAt,
      durationMs: durationMs ?? this.durationMs,
      actualSteps: actualSteps ?? this.actualSteps,
      detectedSteps: detectedSteps ?? this.detectedSteps,
      source: source ?? this.source,
      samples: samples ?? this.samples,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (recordedAt.present) {
      map['recorded_at'] = Variable<int>(recordedAt.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (actualSteps.present) {
      map['actual_steps'] = Variable<int>(actualSteps.value);
    }
    if (detectedSteps.present) {
      map['detected_steps'] = Variable<int>(detectedSteps.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (samples.present) {
      map['samples'] = Variable<Uint8List>(samples.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CalibrationSessionsCompanion(')
          ..write('id: $id, ')
          ..write('recordedAt: $recordedAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('actualSteps: $actualSteps, ')
          ..write('detectedSteps: $detectedSteps, ')
          ..write('source: $source, ')
          ..write('samples: $samples')
          ..write(')'))
        .toString();
  }
}

class $CalibrationVersionsTable extends CalibrationVersions
    with TableInfo<$CalibrationVersionsTable, CalibrationVersion> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalibrationVersionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _paramsJsonMeta = const VerificationMeta(
    'paramsJson',
  );
  @override
  late final GeneratedColumn<String> paramsJson = GeneratedColumn<String>(
    'params_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 16,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _holdoutErrorMeta = const VerificationMeta(
    'holdoutError',
  );
  @override
  late final GeneratedColumn<double> holdoutError = GeneratedColumn<double>(
    'holdout_error',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baselineErrorMeta = const VerificationMeta(
    'baselineError',
  );
  @override
  late final GeneratedColumn<double> baselineError = GeneratedColumn<double>(
    'baseline_error',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sessionCountMeta = const VerificationMeta(
    'sessionCount',
  );
  @override
  late final GeneratedColumn<int> sessionCount = GeneratedColumn<int>(
    'session_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isActiveMeta = const VerificationMeta(
    'isActive',
  );
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
    'is_active',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_active" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    createdAt,
    paramsJson,
    source,
    holdoutError,
    baselineError,
    sessionCount,
    isActive,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calibration_versions';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalibrationVersion> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('params_json')) {
      context.handle(
        _paramsJsonMeta,
        paramsJson.isAcceptableOrUnknown(data['params_json']!, _paramsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_paramsJsonMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('holdout_error')) {
      context.handle(
        _holdoutErrorMeta,
        holdoutError.isAcceptableOrUnknown(
          data['holdout_error']!,
          _holdoutErrorMeta,
        ),
      );
    }
    if (data.containsKey('baseline_error')) {
      context.handle(
        _baselineErrorMeta,
        baselineError.isAcceptableOrUnknown(
          data['baseline_error']!,
          _baselineErrorMeta,
        ),
      );
    }
    if (data.containsKey('session_count')) {
      context.handle(
        _sessionCountMeta,
        sessionCount.isAcceptableOrUnknown(
          data['session_count']!,
          _sessionCountMeta,
        ),
      );
    }
    if (data.containsKey('is_active')) {
      context.handle(
        _isActiveMeta,
        isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CalibrationVersion map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalibrationVersion(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      paramsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}params_json'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      holdoutError: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}holdout_error'],
      ),
      baselineError: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}baseline_error'],
      ),
      sessionCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}session_count'],
      )!,
      isActive: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_active'],
      )!,
    );
  }

  @override
  $CalibrationVersionsTable createAlias(String alias) {
    return $CalibrationVersionsTable(attachedDatabase, alias);
  }
}

class CalibrationVersion extends DataClass
    implements Insertable<CalibrationVersion> {
  final int id;
  final int createdAt;
  final String paramsJson;

  /// 'factory', 'manual', 'automatic', or 'manual-slider'.
  final String source;
  final double? holdoutError;
  final double? baselineError;
  final int sessionCount;
  final bool isActive;
  const CalibrationVersion({
    required this.id,
    required this.createdAt,
    required this.paramsJson,
    required this.source,
    this.holdoutError,
    this.baselineError,
    required this.sessionCount,
    required this.isActive,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['created_at'] = Variable<int>(createdAt);
    map['params_json'] = Variable<String>(paramsJson);
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || holdoutError != null) {
      map['holdout_error'] = Variable<double>(holdoutError);
    }
    if (!nullToAbsent || baselineError != null) {
      map['baseline_error'] = Variable<double>(baselineError);
    }
    map['session_count'] = Variable<int>(sessionCount);
    map['is_active'] = Variable<bool>(isActive);
    return map;
  }

  CalibrationVersionsCompanion toCompanion(bool nullToAbsent) {
    return CalibrationVersionsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      paramsJson: Value(paramsJson),
      source: Value(source),
      holdoutError: holdoutError == null && nullToAbsent
          ? const Value.absent()
          : Value(holdoutError),
      baselineError: baselineError == null && nullToAbsent
          ? const Value.absent()
          : Value(baselineError),
      sessionCount: Value(sessionCount),
      isActive: Value(isActive),
    );
  }

  factory CalibrationVersion.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalibrationVersion(
      id: serializer.fromJson<int>(json['id']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      paramsJson: serializer.fromJson<String>(json['paramsJson']),
      source: serializer.fromJson<String>(json['source']),
      holdoutError: serializer.fromJson<double?>(json['holdoutError']),
      baselineError: serializer.fromJson<double?>(json['baselineError']),
      sessionCount: serializer.fromJson<int>(json['sessionCount']),
      isActive: serializer.fromJson<bool>(json['isActive']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'createdAt': serializer.toJson<int>(createdAt),
      'paramsJson': serializer.toJson<String>(paramsJson),
      'source': serializer.toJson<String>(source),
      'holdoutError': serializer.toJson<double?>(holdoutError),
      'baselineError': serializer.toJson<double?>(baselineError),
      'sessionCount': serializer.toJson<int>(sessionCount),
      'isActive': serializer.toJson<bool>(isActive),
    };
  }

  CalibrationVersion copyWith({
    int? id,
    int? createdAt,
    String? paramsJson,
    String? source,
    Value<double?> holdoutError = const Value.absent(),
    Value<double?> baselineError = const Value.absent(),
    int? sessionCount,
    bool? isActive,
  }) => CalibrationVersion(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    paramsJson: paramsJson ?? this.paramsJson,
    source: source ?? this.source,
    holdoutError: holdoutError.present ? holdoutError.value : this.holdoutError,
    baselineError: baselineError.present
        ? baselineError.value
        : this.baselineError,
    sessionCount: sessionCount ?? this.sessionCount,
    isActive: isActive ?? this.isActive,
  );
  CalibrationVersion copyWithCompanion(CalibrationVersionsCompanion data) {
    return CalibrationVersion(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      paramsJson: data.paramsJson.present
          ? data.paramsJson.value
          : this.paramsJson,
      source: data.source.present ? data.source.value : this.source,
      holdoutError: data.holdoutError.present
          ? data.holdoutError.value
          : this.holdoutError,
      baselineError: data.baselineError.present
          ? data.baselineError.value
          : this.baselineError,
      sessionCount: data.sessionCount.present
          ? data.sessionCount.value
          : this.sessionCount,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalibrationVersion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('paramsJson: $paramsJson, ')
          ..write('source: $source, ')
          ..write('holdoutError: $holdoutError, ')
          ..write('baselineError: $baselineError, ')
          ..write('sessionCount: $sessionCount, ')
          ..write('isActive: $isActive')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    createdAt,
    paramsJson,
    source,
    holdoutError,
    baselineError,
    sessionCount,
    isActive,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalibrationVersion &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.paramsJson == this.paramsJson &&
          other.source == this.source &&
          other.holdoutError == this.holdoutError &&
          other.baselineError == this.baselineError &&
          other.sessionCount == this.sessionCount &&
          other.isActive == this.isActive);
}

class CalibrationVersionsCompanion extends UpdateCompanion<CalibrationVersion> {
  final Value<int> id;
  final Value<int> createdAt;
  final Value<String> paramsJson;
  final Value<String> source;
  final Value<double?> holdoutError;
  final Value<double?> baselineError;
  final Value<int> sessionCount;
  final Value<bool> isActive;
  const CalibrationVersionsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.paramsJson = const Value.absent(),
    this.source = const Value.absent(),
    this.holdoutError = const Value.absent(),
    this.baselineError = const Value.absent(),
    this.sessionCount = const Value.absent(),
    this.isActive = const Value.absent(),
  });
  CalibrationVersionsCompanion.insert({
    this.id = const Value.absent(),
    required int createdAt,
    required String paramsJson,
    required String source,
    this.holdoutError = const Value.absent(),
    this.baselineError = const Value.absent(),
    this.sessionCount = const Value.absent(),
    this.isActive = const Value.absent(),
  }) : createdAt = Value(createdAt),
       paramsJson = Value(paramsJson),
       source = Value(source);
  static Insertable<CalibrationVersion> custom({
    Expression<int>? id,
    Expression<int>? createdAt,
    Expression<String>? paramsJson,
    Expression<String>? source,
    Expression<double>? holdoutError,
    Expression<double>? baselineError,
    Expression<int>? sessionCount,
    Expression<bool>? isActive,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (paramsJson != null) 'params_json': paramsJson,
      if (source != null) 'source': source,
      if (holdoutError != null) 'holdout_error': holdoutError,
      if (baselineError != null) 'baseline_error': baselineError,
      if (sessionCount != null) 'session_count': sessionCount,
      if (isActive != null) 'is_active': isActive,
    });
  }

  CalibrationVersionsCompanion copyWith({
    Value<int>? id,
    Value<int>? createdAt,
    Value<String>? paramsJson,
    Value<String>? source,
    Value<double?>? holdoutError,
    Value<double?>? baselineError,
    Value<int>? sessionCount,
    Value<bool>? isActive,
  }) {
    return CalibrationVersionsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      paramsJson: paramsJson ?? this.paramsJson,
      source: source ?? this.source,
      holdoutError: holdoutError ?? this.holdoutError,
      baselineError: baselineError ?? this.baselineError,
      sessionCount: sessionCount ?? this.sessionCount,
      isActive: isActive ?? this.isActive,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (paramsJson.present) {
      map['params_json'] = Variable<String>(paramsJson.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (holdoutError.present) {
      map['holdout_error'] = Variable<double>(holdoutError.value);
    }
    if (baselineError.present) {
      map['baseline_error'] = Variable<double>(baselineError.value);
    }
    if (sessionCount.present) {
      map['session_count'] = Variable<int>(sessionCount.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CalibrationVersionsCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('paramsJson: $paramsJson, ')
          ..write('source: $source, ')
          ..write('holdoutError: $holdoutError, ')
          ..write('baselineError: $baselineError, ')
          ..write('sessionCount: $sessionCount, ')
          ..write('isActive: $isActive')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $StepMinutesTable stepMinutes = $StepMinutesTable(this);
  late final $CalibrationSessionsTable calibrationSessions =
      $CalibrationSessionsTable(this);
  late final $CalibrationVersionsTable calibrationVersions =
      $CalibrationVersionsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    stepMinutes,
    calibrationSessions,
    calibrationVersions,
  ];
}

typedef $$StepMinutesTableCreateCompanionBuilder =
    StepMinutesCompanion Function({Value<int> minuteEpoch, required int steps});
typedef $$StepMinutesTableUpdateCompanionBuilder =
    StepMinutesCompanion Function({Value<int> minuteEpoch, Value<int> steps});

class $$StepMinutesTableFilterComposer
    extends Composer<_$AppDatabase, $StepMinutesTable> {
  $$StepMinutesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get minuteEpoch => $composableBuilder(
    column: $table.minuteEpoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get steps => $composableBuilder(
    column: $table.steps,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StepMinutesTableOrderingComposer
    extends Composer<_$AppDatabase, $StepMinutesTable> {
  $$StepMinutesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get minuteEpoch => $composableBuilder(
    column: $table.minuteEpoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get steps => $composableBuilder(
    column: $table.steps,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StepMinutesTableAnnotationComposer
    extends Composer<_$AppDatabase, $StepMinutesTable> {
  $$StepMinutesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get minuteEpoch => $composableBuilder(
    column: $table.minuteEpoch,
    builder: (column) => column,
  );

  GeneratedColumn<int> get steps =>
      $composableBuilder(column: $table.steps, builder: (column) => column);
}

class $$StepMinutesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $StepMinutesTable,
          StepMinute,
          $$StepMinutesTableFilterComposer,
          $$StepMinutesTableOrderingComposer,
          $$StepMinutesTableAnnotationComposer,
          $$StepMinutesTableCreateCompanionBuilder,
          $$StepMinutesTableUpdateCompanionBuilder,
          (
            StepMinute,
            BaseReferences<_$AppDatabase, $StepMinutesTable, StepMinute>,
          ),
          StepMinute,
          PrefetchHooks Function()
        > {
  $$StepMinutesTableTableManager(_$AppDatabase db, $StepMinutesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StepMinutesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StepMinutesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StepMinutesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> minuteEpoch = const Value.absent(),
                Value<int> steps = const Value.absent(),
              }) =>
                  StepMinutesCompanion(minuteEpoch: minuteEpoch, steps: steps),
          createCompanionCallback:
              ({
                Value<int> minuteEpoch = const Value.absent(),
                required int steps,
              }) => StepMinutesCompanion.insert(
                minuteEpoch: minuteEpoch,
                steps: steps,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StepMinutesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $StepMinutesTable,
      StepMinute,
      $$StepMinutesTableFilterComposer,
      $$StepMinutesTableOrderingComposer,
      $$StepMinutesTableAnnotationComposer,
      $$StepMinutesTableCreateCompanionBuilder,
      $$StepMinutesTableUpdateCompanionBuilder,
      (
        StepMinute,
        BaseReferences<_$AppDatabase, $StepMinutesTable, StepMinute>,
      ),
      StepMinute,
      PrefetchHooks Function()
    >;
typedef $$CalibrationSessionsTableCreateCompanionBuilder =
    CalibrationSessionsCompanion Function({
      Value<int> id,
      required int recordedAt,
      required int durationMs,
      required int actualSteps,
      required int detectedSteps,
      required String source,
      required Uint8List samples,
    });
typedef $$CalibrationSessionsTableUpdateCompanionBuilder =
    CalibrationSessionsCompanion Function({
      Value<int> id,
      Value<int> recordedAt,
      Value<int> durationMs,
      Value<int> actualSteps,
      Value<int> detectedSteps,
      Value<String> source,
      Value<Uint8List> samples,
    });

class $$CalibrationSessionsTableFilterComposer
    extends Composer<_$AppDatabase, $CalibrationSessionsTable> {
  $$CalibrationSessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordedAt => $composableBuilder(
    column: $table.recordedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get actualSteps => $composableBuilder(
    column: $table.actualSteps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get detectedSteps => $composableBuilder(
    column: $table.detectedSteps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get samples => $composableBuilder(
    column: $table.samples,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CalibrationSessionsTableOrderingComposer
    extends Composer<_$AppDatabase, $CalibrationSessionsTable> {
  $$CalibrationSessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordedAt => $composableBuilder(
    column: $table.recordedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get actualSteps => $composableBuilder(
    column: $table.actualSteps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get detectedSteps => $composableBuilder(
    column: $table.detectedSteps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get samples => $composableBuilder(
    column: $table.samples,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CalibrationSessionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CalibrationSessionsTable> {
  $$CalibrationSessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get recordedAt => $composableBuilder(
    column: $table.recordedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get actualSteps => $composableBuilder(
    column: $table.actualSteps,
    builder: (column) => column,
  );

  GeneratedColumn<int> get detectedSteps => $composableBuilder(
    column: $table.detectedSteps,
    builder: (column) => column,
  );

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<Uint8List> get samples =>
      $composableBuilder(column: $table.samples, builder: (column) => column);
}

class $$CalibrationSessionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CalibrationSessionsTable,
          CalibrationSession,
          $$CalibrationSessionsTableFilterComposer,
          $$CalibrationSessionsTableOrderingComposer,
          $$CalibrationSessionsTableAnnotationComposer,
          $$CalibrationSessionsTableCreateCompanionBuilder,
          $$CalibrationSessionsTableUpdateCompanionBuilder,
          (
            CalibrationSession,
            BaseReferences<
              _$AppDatabase,
              $CalibrationSessionsTable,
              CalibrationSession
            >,
          ),
          CalibrationSession,
          PrefetchHooks Function()
        > {
  $$CalibrationSessionsTableTableManager(
    _$AppDatabase db,
    $CalibrationSessionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalibrationSessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CalibrationSessionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CalibrationSessionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> recordedAt = const Value.absent(),
                Value<int> durationMs = const Value.absent(),
                Value<int> actualSteps = const Value.absent(),
                Value<int> detectedSteps = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<Uint8List> samples = const Value.absent(),
              }) => CalibrationSessionsCompanion(
                id: id,
                recordedAt: recordedAt,
                durationMs: durationMs,
                actualSteps: actualSteps,
                detectedSteps: detectedSteps,
                source: source,
                samples: samples,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int recordedAt,
                required int durationMs,
                required int actualSteps,
                required int detectedSteps,
                required String source,
                required Uint8List samples,
              }) => CalibrationSessionsCompanion.insert(
                id: id,
                recordedAt: recordedAt,
                durationMs: durationMs,
                actualSteps: actualSteps,
                detectedSteps: detectedSteps,
                source: source,
                samples: samples,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CalibrationSessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CalibrationSessionsTable,
      CalibrationSession,
      $$CalibrationSessionsTableFilterComposer,
      $$CalibrationSessionsTableOrderingComposer,
      $$CalibrationSessionsTableAnnotationComposer,
      $$CalibrationSessionsTableCreateCompanionBuilder,
      $$CalibrationSessionsTableUpdateCompanionBuilder,
      (
        CalibrationSession,
        BaseReferences<
          _$AppDatabase,
          $CalibrationSessionsTable,
          CalibrationSession
        >,
      ),
      CalibrationSession,
      PrefetchHooks Function()
    >;
typedef $$CalibrationVersionsTableCreateCompanionBuilder =
    CalibrationVersionsCompanion Function({
      Value<int> id,
      required int createdAt,
      required String paramsJson,
      required String source,
      Value<double?> holdoutError,
      Value<double?> baselineError,
      Value<int> sessionCount,
      Value<bool> isActive,
    });
typedef $$CalibrationVersionsTableUpdateCompanionBuilder =
    CalibrationVersionsCompanion Function({
      Value<int> id,
      Value<int> createdAt,
      Value<String> paramsJson,
      Value<String> source,
      Value<double?> holdoutError,
      Value<double?> baselineError,
      Value<int> sessionCount,
      Value<bool> isActive,
    });

class $$CalibrationVersionsTableFilterComposer
    extends Composer<_$AppDatabase, $CalibrationVersionsTable> {
  $$CalibrationVersionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get paramsJson => $composableBuilder(
    column: $table.paramsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get holdoutError => $composableBuilder(
    column: $table.holdoutError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get baselineError => $composableBuilder(
    column: $table.baselineError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sessionCount => $composableBuilder(
    column: $table.sessionCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CalibrationVersionsTableOrderingComposer
    extends Composer<_$AppDatabase, $CalibrationVersionsTable> {
  $$CalibrationVersionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get paramsJson => $composableBuilder(
    column: $table.paramsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get holdoutError => $composableBuilder(
    column: $table.holdoutError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get baselineError => $composableBuilder(
    column: $table.baselineError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sessionCount => $composableBuilder(
    column: $table.sessionCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isActive => $composableBuilder(
    column: $table.isActive,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CalibrationVersionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CalibrationVersionsTable> {
  $$CalibrationVersionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get paramsJson => $composableBuilder(
    column: $table.paramsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<double> get holdoutError => $composableBuilder(
    column: $table.holdoutError,
    builder: (column) => column,
  );

  GeneratedColumn<double> get baselineError => $composableBuilder(
    column: $table.baselineError,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sessionCount => $composableBuilder(
    column: $table.sessionCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);
}

class $$CalibrationVersionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CalibrationVersionsTable,
          CalibrationVersion,
          $$CalibrationVersionsTableFilterComposer,
          $$CalibrationVersionsTableOrderingComposer,
          $$CalibrationVersionsTableAnnotationComposer,
          $$CalibrationVersionsTableCreateCompanionBuilder,
          $$CalibrationVersionsTableUpdateCompanionBuilder,
          (
            CalibrationVersion,
            BaseReferences<
              _$AppDatabase,
              $CalibrationVersionsTable,
              CalibrationVersion
            >,
          ),
          CalibrationVersion,
          PrefetchHooks Function()
        > {
  $$CalibrationVersionsTableTableManager(
    _$AppDatabase db,
    $CalibrationVersionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalibrationVersionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CalibrationVersionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CalibrationVersionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> paramsJson = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<double?> holdoutError = const Value.absent(),
                Value<double?> baselineError = const Value.absent(),
                Value<int> sessionCount = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
              }) => CalibrationVersionsCompanion(
                id: id,
                createdAt: createdAt,
                paramsJson: paramsJson,
                source: source,
                holdoutError: holdoutError,
                baselineError: baselineError,
                sessionCount: sessionCount,
                isActive: isActive,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int createdAt,
                required String paramsJson,
                required String source,
                Value<double?> holdoutError = const Value.absent(),
                Value<double?> baselineError = const Value.absent(),
                Value<int> sessionCount = const Value.absent(),
                Value<bool> isActive = const Value.absent(),
              }) => CalibrationVersionsCompanion.insert(
                id: id,
                createdAt: createdAt,
                paramsJson: paramsJson,
                source: source,
                holdoutError: holdoutError,
                baselineError: baselineError,
                sessionCount: sessionCount,
                isActive: isActive,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CalibrationVersionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CalibrationVersionsTable,
      CalibrationVersion,
      $$CalibrationVersionsTableFilterComposer,
      $$CalibrationVersionsTableOrderingComposer,
      $$CalibrationVersionsTableAnnotationComposer,
      $$CalibrationVersionsTableCreateCompanionBuilder,
      $$CalibrationVersionsTableUpdateCompanionBuilder,
      (
        CalibrationVersion,
        BaseReferences<
          _$AppDatabase,
          $CalibrationVersionsTable,
          CalibrationVersion
        >,
      ),
      CalibrationVersion,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$StepMinutesTableTableManager get stepMinutes =>
      $$StepMinutesTableTableManager(_db, _db.stepMinutes);
  $$CalibrationSessionsTableTableManager get calibrationSessions =>
      $$CalibrationSessionsTableTableManager(_db, _db.calibrationSessions);
  $$CalibrationVersionsTableTableManager get calibrationVersions =>
      $$CalibrationVersionsTableTableManager(_db, _db.calibrationVersions);
}
