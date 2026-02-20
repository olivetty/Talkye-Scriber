// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'engine.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$FfiEngineEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FfiEngineEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'FfiEngineEvent()';
}


}

/// @nodoc
class $FfiEngineEventCopyWith<$Res>  {
$FfiEngineEventCopyWith(FfiEngineEvent _, $Res Function(FfiEngineEvent) __);
}


/// Adds pattern-matching-related methods to [FfiEngineEvent].
extension FfiEngineEventPatterns on FfiEngineEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( FfiEngineEvent_StatusChanged value)?  statusChanged,TResult Function( FfiEngineEvent_Transcript value)?  transcript,TResult Function( FfiEngineEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case FfiEngineEvent_StatusChanged() when statusChanged != null:
return statusChanged(_that);case FfiEngineEvent_Transcript() when transcript != null:
return transcript(_that);case FfiEngineEvent_Error() when error != null:
return error(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( FfiEngineEvent_StatusChanged value)  statusChanged,required TResult Function( FfiEngineEvent_Transcript value)  transcript,required TResult Function( FfiEngineEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case FfiEngineEvent_StatusChanged():
return statusChanged(_that);case FfiEngineEvent_Transcript():
return transcript(_that);case FfiEngineEvent_Error():
return error(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( FfiEngineEvent_StatusChanged value)?  statusChanged,TResult? Function( FfiEngineEvent_Transcript value)?  transcript,TResult? Function( FfiEngineEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case FfiEngineEvent_StatusChanged() when statusChanged != null:
return statusChanged(_that);case FfiEngineEvent_Transcript() when transcript != null:
return transcript(_that);case FfiEngineEvent_Error() when error != null:
return error(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String status)?  statusChanged,TResult Function( String original,  String translated)?  transcript,TResult Function( String message)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case FfiEngineEvent_StatusChanged() when statusChanged != null:
return statusChanged(_that.status);case FfiEngineEvent_Transcript() when transcript != null:
return transcript(_that.original,_that.translated);case FfiEngineEvent_Error() when error != null:
return error(_that.message);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String status)  statusChanged,required TResult Function( String original,  String translated)  transcript,required TResult Function( String message)  error,}) {final _that = this;
switch (_that) {
case FfiEngineEvent_StatusChanged():
return statusChanged(_that.status);case FfiEngineEvent_Transcript():
return transcript(_that.original,_that.translated);case FfiEngineEvent_Error():
return error(_that.message);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String status)?  statusChanged,TResult? Function( String original,  String translated)?  transcript,TResult? Function( String message)?  error,}) {final _that = this;
switch (_that) {
case FfiEngineEvent_StatusChanged() when statusChanged != null:
return statusChanged(_that.status);case FfiEngineEvent_Transcript() when transcript != null:
return transcript(_that.original,_that.translated);case FfiEngineEvent_Error() when error != null:
return error(_that.message);case _:
  return null;

}
}

}

/// @nodoc


class FfiEngineEvent_StatusChanged extends FfiEngineEvent {
  const FfiEngineEvent_StatusChanged({required this.status}): super._();
  

 final  String status;

/// Create a copy of FfiEngineEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FfiEngineEvent_StatusChangedCopyWith<FfiEngineEvent_StatusChanged> get copyWith => _$FfiEngineEvent_StatusChangedCopyWithImpl<FfiEngineEvent_StatusChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FfiEngineEvent_StatusChanged&&(identical(other.status, status) || other.status == status));
}


@override
int get hashCode => Object.hash(runtimeType,status);

@override
String toString() {
  return 'FfiEngineEvent.statusChanged(status: $status)';
}


}

/// @nodoc
abstract mixin class $FfiEngineEvent_StatusChangedCopyWith<$Res> implements $FfiEngineEventCopyWith<$Res> {
  factory $FfiEngineEvent_StatusChangedCopyWith(FfiEngineEvent_StatusChanged value, $Res Function(FfiEngineEvent_StatusChanged) _then) = _$FfiEngineEvent_StatusChangedCopyWithImpl;
@useResult
$Res call({
 String status
});




}
/// @nodoc
class _$FfiEngineEvent_StatusChangedCopyWithImpl<$Res>
    implements $FfiEngineEvent_StatusChangedCopyWith<$Res> {
  _$FfiEngineEvent_StatusChangedCopyWithImpl(this._self, this._then);

  final FfiEngineEvent_StatusChanged _self;
  final $Res Function(FfiEngineEvent_StatusChanged) _then;

/// Create a copy of FfiEngineEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? status = null,}) {
  return _then(FfiEngineEvent_StatusChanged(
status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class FfiEngineEvent_Transcript extends FfiEngineEvent {
  const FfiEngineEvent_Transcript({required this.original, required this.translated}): super._();
  

 final  String original;
 final  String translated;

/// Create a copy of FfiEngineEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FfiEngineEvent_TranscriptCopyWith<FfiEngineEvent_Transcript> get copyWith => _$FfiEngineEvent_TranscriptCopyWithImpl<FfiEngineEvent_Transcript>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FfiEngineEvent_Transcript&&(identical(other.original, original) || other.original == original)&&(identical(other.translated, translated) || other.translated == translated));
}


@override
int get hashCode => Object.hash(runtimeType,original,translated);

@override
String toString() {
  return 'FfiEngineEvent.transcript(original: $original, translated: $translated)';
}


}

/// @nodoc
abstract mixin class $FfiEngineEvent_TranscriptCopyWith<$Res> implements $FfiEngineEventCopyWith<$Res> {
  factory $FfiEngineEvent_TranscriptCopyWith(FfiEngineEvent_Transcript value, $Res Function(FfiEngineEvent_Transcript) _then) = _$FfiEngineEvent_TranscriptCopyWithImpl;
@useResult
$Res call({
 String original, String translated
});




}
/// @nodoc
class _$FfiEngineEvent_TranscriptCopyWithImpl<$Res>
    implements $FfiEngineEvent_TranscriptCopyWith<$Res> {
  _$FfiEngineEvent_TranscriptCopyWithImpl(this._self, this._then);

  final FfiEngineEvent_Transcript _self;
  final $Res Function(FfiEngineEvent_Transcript) _then;

/// Create a copy of FfiEngineEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? original = null,Object? translated = null,}) {
  return _then(FfiEngineEvent_Transcript(
original: null == original ? _self.original : original // ignore: cast_nullable_to_non_nullable
as String,translated: null == translated ? _self.translated : translated // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class FfiEngineEvent_Error extends FfiEngineEvent {
  const FfiEngineEvent_Error({required this.message}): super._();
  

 final  String message;

/// Create a copy of FfiEngineEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$FfiEngineEvent_ErrorCopyWith<FfiEngineEvent_Error> get copyWith => _$FfiEngineEvent_ErrorCopyWithImpl<FfiEngineEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is FfiEngineEvent_Error&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'FfiEngineEvent.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $FfiEngineEvent_ErrorCopyWith<$Res> implements $FfiEngineEventCopyWith<$Res> {
  factory $FfiEngineEvent_ErrorCopyWith(FfiEngineEvent_Error value, $Res Function(FfiEngineEvent_Error) _then) = _$FfiEngineEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$FfiEngineEvent_ErrorCopyWithImpl<$Res>
    implements $FfiEngineEvent_ErrorCopyWith<$Res> {
  _$FfiEngineEvent_ErrorCopyWithImpl(this._self, this._then);

  final FfiEngineEvent_Error _self;
  final $Res Function(FfiEngineEvent_Error) _then;

/// Create a copy of FfiEngineEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(FfiEngineEvent_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
