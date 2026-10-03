import 'package:flutter_test/flutter_test.dart';
import 'package:registro_elettronico/core/data/local/moor_database.dart';
import 'package:registro_elettronico/feature/homework/data/homework_agenda_sync.dart';
import 'package:registro_elettronico/feature/homework/data/homework_remote_datasource.dart';

Homework _homework({
  required String id,
  String subject = 'Matematica',
  String teacher = 'Docente',
  String instructions = 'Esercizi',
  String period = 'Scadenza: 18/09/2026',
}) =>
    Homework(
      id: id,
      subject: subject,
      teacher: teacher,
      instructions: instructions,
      period: period,
    );

AgendaEventLocalModel _event({
  required int id,
  required String code,
}) =>
    AgendaEventLocalModel(
      evtId: id,
      evtCode: code,
      begin: DateTime(2026, 9, 19),
      end: DateTime(2026, 9, 19),
      isFullDay: false,
      notes: '',
      authorName: '',
      classDesc: '',
      subjectId: 0,
      subjectDesc: '',
      isLocal: false,
      labelColor: null,
      title: '',
    );

void main() {
  test('maps homework into local agenda event with stable namespace', () {
    final homework = _homework(id: '42');

    final event = homeworkToAgendaEvent(homework);

    expect(event.evtId, homeworkAgendaEventId('42'));
    expect(event.evtId! < 0, true);
    expect(event.evtCode, 'homework:42');
    expect(event.isLocal, true);
    expect(event.title, 'Compito');
    expect(event.subjectDesc, 'Matematica');
    expect(event.notes, contains('Esercizi'));
    expect(event.notes, contains('Scadenza'));
  });

  test('removes only stale homework agenda events', () {
    final stale = _event(id: 1, code: 'homework:old');
    final current = _event(id: 2, code: 'homework:new');
    final lesson = _event(id: 3, code: 'AGND');

    final removed = homeworkAgendaEventsMissingFromHomeworks(
      localEvents: [stale, current, lesson],
      homeworkCodes: {'homework:new'},
    );

    expect(removed, [stale]);
  });
}
