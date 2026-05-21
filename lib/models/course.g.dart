// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'course.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CourseAdapter extends TypeAdapter<Course> {
  @override
  final int typeId = 0;

  @override
  Course read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Course(
      id: fields[0] as String,
      name: fields[1] as String,
      teacher: fields[2] as String?,
      location: fields[3] as String?,
      day: fields[4] as int,
      time: fields[5] as int,
      duration: fields[6] as int? ?? 1,
      weeks: fields[7] as String?,
      color: fields[8] as String? ?? '#4A90E2',
    );
  }

  @override
  void write(BinaryWriter writer, Course obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.teacher)
      ..writeByte(3)
      ..write(obj.location)
      ..writeByte(4)
      ..write(obj.day)
      ..writeByte(5)
      ..write(obj.time)
      ..writeByte(6)
      ..write(obj.duration)
      ..writeByte(7)
      ..write(obj.weeks)
      ..writeByte(8)
      ..write(obj.color);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CourseAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
