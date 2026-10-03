import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:registro_elettronico/core/data/local/moor_database.dart';
import 'package:registro_elettronico/feature/agenda/data/datasource/local/agenda_local_datasource.dart';
import 'package:registro_elettronico/feature/homework/data/homework_remote_datasource.dart';

const String _homeworkAgendaCodePrefix = 'homework:';
const String _homeworkAgendaTitle = 'Compito';
const int _homeworkAgendaSubjectId = -2;

Future<void> syncHomeworkAgendaEvents({
  required AgendaLocalDatasource agendaLocalDatasource,
  required List<Homework> homeworks,
}) async {
  final localEvents = await agendaLocalDatasource.getAllEvents();
  final homeworkEvents = homeworks.map(homeworkToAgendaEvent).toList();
  final homeworkCodes = homeworkEvents.map((event) => event.evtCode).toSet();

  final staleHomeworkEvents = homeworkAgendaEventsMissingFromHomeworks(
    localEvents: localEvents,
    homeworkCodes: homeworkCodes,
  );

  await agendaLocalDatasource.insertEvents(homeworkEvents);
  if (staleHomeworkEvents.isNotEmpty) {
    await agendaLocalDatasource.deleteEvents(staleHomeworkEvents);
  }
}

List<AgendaEventLocalModel> homeworkAgendaEventsMissingFromHomeworks({
  required Iterable<AgendaEventLocalModel> localEvents,
  required Iterable<String?> homeworkCodes,
}) =>
    localEvents
        .where((event) =>
            isHomeworkAgendaEvent(event) && !homeworkCodes.contains(event.evtCode))
        .toList();

bool isHomeworkAgendaEvent(AgendaEventLocalModel event) =>
    event.evtCode.startsWith(_homeworkAgendaCodePrefix);

AgendaEventLocalModel homeworkToAgendaEvent(Homework homework) {
  final date = _homeworkDate(homework);
  return AgendaEventLocalModel(
    evtId: homeworkAgendaEventId(homework.id),
    evtCode: _homeworkAgendaCode(homework.id),
    begin: date,
    end: date,
    isFullDay: true,
    notes: _homeworkNotes(homework),
    authorName: homework.teacher,
    classDesc: '',
    subjectId: _homeworkAgendaSubjectId,
    subjectDesc: homework.subject,
    isLocal: true,
    labelColor: Colors.blue.value.toString(),
    title: _homeworkAgendaTitle,
  );
}

int homeworkAgendaEventId(String homeworkId) {
  final digest = sha1.convert(utf8.encode(homeworkId)).bytes;
  int value = 0;
  for (int i = 0; i < 8; i++) {
    value = (value << 8) | digest[i];
  }
  value = value & 0x7FFFFFFFFFFFFFFF;
  return -(value == 0 ? 1 : value);
}

String _homeworkAgendaCode(String homeworkId) =>
    '$_homeworkAgendaCodePrefix$homeworkId';

DateTime _homeworkDate(Homework homework) {
  final deadline = homework.deadline;
  if (deadline != null) {
    return DateTime(deadline.year, deadline.month, deadline.day, 8);
  }
  final matches = RegExp(r'(\d{2})/(\d{2})/(\d{4})').allMatches(homework.period);
  if (matches.isEmpty) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, 8);
  }
  final date = matches.last;
  return DateTime(
    int.parse(date.group(3)!),
    int.parse(date.group(2)!),
    int.parse(date.group(1)!),
    8,
  );
}

String _homeworkNotes(Homework homework) {
  final values = <String>[
    homework.instructions.trim(),
    homework.period.trim(),
  ].where((value) => value.isNotEmpty).toList();
  return values.join('\n');
}
