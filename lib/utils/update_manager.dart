import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:fimber/fimber.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:registro_elettronico/core/infrastructure/app_injection.dart';
import 'package:registro_elettronico/core/data/local/moor_database.dart';
import 'package:registro_elettronico/core/infrastructure/error/failures.dart';
import 'package:registro_elettronico/core/infrastructure/error/successes.dart';
import 'package:registro_elettronico/core/infrastructure/localizations/app_localizations.dart';
import 'package:registro_elettronico/core/infrastructure/notification/local_content_notification_service.dart';
import 'package:registro_elettronico/core/infrastructure/notification/local_notification.dart';
import 'package:flutter/services.dart';
import 'package:registro_elettronico/feature/absences/domain/repository/absences_repository.dart';
import 'package:registro_elettronico/feature/agenda/domain/repository/agenda_repository.dart';
import 'package:registro_elettronico/feature/didactics/domain/repository/didactics_repository.dart';
import 'package:registro_elettronico/feature/grades/domain/model/grades_section.dart';
import 'package:registro_elettronico/feature/grades/domain/repository/grades_repository.dart';
import 'package:registro_elettronico/feature/homework/data/homework_remote_datasource.dart';
import 'package:registro_elettronico/feature/homework/data/homework_agenda_sync.dart';
import 'package:registro_elettronico/feature/lessons/domain/repository/lessons_repository.dart';
import 'package:registro_elettronico/feature/notes/domain/repository/notes_repository.dart';
import 'package:registro_elettronico/feature/noticeboard/domain/repository/noticeboard_repository.dart';
import 'package:registro_elettronico/feature/periods/domain/repository/periods_repository.dart';
import 'package:registro_elettronico/feature/scrutini/domain/repository/documents_repository.dart';
import 'package:registro_elettronico/feature/subjects/domain/repository/subjects_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'constants/preferences_constants.dart';

/// Class that manages all the updates
class SRUpdateManager {
  final SharedPreferences? sharedPreferences;
  final AbsencesRepository? absencesRepository;
  final AgendaRepository? agendaRepository;
  final DidacticsRepository? didacticsRepository;
  final GradesRepository? gradesRepository;
  final LessonsRepository? lessonsRepository;
  final NoticeboardRepository? noticesRepository;
  final PeriodsRepository? periodsRepository;
  final SubjectsRepository? subjectsRepository;
  final DocumentsRepository? documentsRepository;
  final NotesRepository? notesRepository;

  SRUpdateManager({
    required this.sharedPreferences,
    required this.absencesRepository,
    required this.agendaRepository,
    required this.didacticsRepository,
    required this.gradesRepository,
    required this.lessonsRepository,
    required this.noticesRepository,
    required this.periodsRepository,
    required this.subjectsRepository,
    required this.documentsRepository,
    required this.notesRepository,
  });

  Future<void> checkForUpdates() async {
    if (kDebugMode) {
      return;
    }

    final String? databaseName =
        sharedPreferences!.getString(PrefsConstants.databaseName);

    Fimber.i('🔄 [UpdateMANAGER] Checking for db: $databaseName');

    // download di tutti i dati, partenza da 0
    if (_needToUpdateAllData(databaseName: databaseName)) {
      Fimber.i('🔄 [UpdateMANAGER]: Update all data');

      // update all the endpoints
      await updateAllData(databaseName);

      // ponytail: manual data stays local; add an explicit import only if needed.
    } else {
      // se mancano dei dati essenziali
      final needToUpdateVitalData = await _needUpdateVitalData(
        databaseName: databaseName,
      );

      if (needToUpdateVitalData) {
        Fimber.i('🔄 [UpdateMANAGER] Update vital data');

        await sharedPreferences!.setInt(PrefsConstants.lastUpdateVitalData,
            DateTime.now().millisecondsSinceEpoch);

        final PeriodsRepository periodsRepository = sl();
        await periodsRepository.updatePeriods(ifNeeded: false);

        final SubjectsRepository subjectsRepository = sl();
        await subjectsRepository.updateSubjects(ifNeeded: false);
      }

      Fimber.i('🔄 [UpdateMANAGER] Updating home screen data');

      // update all the basic data
      await Future.wait([
        gradesRepository!.updateGrades(ifNeeded: false),
        agendaRepository!.updateAllAgenda(ifNeeded: false),
        lessonsRepository!.updateAllLessons(ifNeeded: false),
      ]);

      await noticesRepository!.updateNotices(ifNeeded: false);
    }

    await _syncHomeworks(notify: true);
    await _notifyNewContent();
    await updateNextEventWidget();
  }

  Future<bool> syncNotificationContent() async {
    await Future.wait([
      gradesRepository!.updateGrades(ifNeeded: false),
      noticesRepository!.updateNotices(ifNeeded: false),
      notesRepository!.updateNotes(),
      didacticsRepository!.updateMaterials(ifNeeded: false),
      absencesRepository!.updateAbsences(),
      documentsRepository!.updateDocuments(),
    ]);
    await _syncHomeworks(notify: true);
    await _notifyNewContent();
    await updateNextEventWidget();
    return true;
  }

  Future<void> updateNextEventWidget() async {
    if (!Platform.isAndroid) return;
    final database = sl<SRDatabase>();
    final now = DateTime.now();
    final events = await database.agendaLocalDatasource.getAllEvents();
    final upcoming = events.where((event) =>
        event.begin != null && event.begin!.isAfter(now)).toList()
      ..sort((a, b) => a.begin!.compareTo(b.begin!));
    final grades = (await database.gradesLocalDatasource.getGrades())
        .where((grade) => grade.eventDate != null)
        .toList()
      ..sort((a, b) => b.eventDate!.compareTo(a.eventDate!));
    final timetable = await database.timetableLocalDatasource.getAllEntries();
    final color = sharedPreferences!.getInt(PrefsConstants.themeColor) ??
        Colors.red.value;
    await const MethodChannel(
      'com.lnlenost.registroelettronico/multi-account',
    ).invokeMethod<void>('updateWidgets', {
      'agenda': upcoming.isEmpty
          ? 'Nessun compito in agenda'
          : upcoming.take(3).map((event) => event.title ?? event.notes).join(' · '),
      'grades': grades.isEmpty
          ? 'Nessun voto disponibile'
          : grades.take(3).map((grade) =>
              '${grade.subjectDesc ?? ''}: ${grade.displayValue ?? ''}').join(' · '),
      'timetable': timetable.isEmpty
          ? 'Orario non disponibile'
          : timetable.take(4).map((entry) => entry.subjectName).join(' · '),
      'color': color,
    });
  }

  Future<void> updateVitalData(BuildContext context) async {
    final update1 = await periodsRepository!.updatePeriods(ifNeeded: false);
    final update2 = await subjectsRepository!.updateSubjects(ifNeeded: false);
    final update3 = await lessonsRepository!.updateAllLessons(ifNeeded: false);
    final updates = [update1, update2, update3];

    await _updateMultipleData(context: context, updates: updates);
  }

  Future<void> updateHomeData(BuildContext context) async {
    final update1 = await gradesRepository!.updateGrades(ifNeeded: false);
    final update2 = await agendaRepository!.updateAllAgenda(ifNeeded: false);
    final update3 =
        await lessonsRepository!.updateTodaysLessons(ifNeeded: false);

    final updates = [update1, update2, update3];

    await _updateMultipleData(context: context, updates: updates);
    await _syncHomeworks(notify: false);
    await updateNextEventWidget();
  }

  Future<void> updateDidacticsData(BuildContext context) async {
    final update1 = await didacticsRepository!.updateMaterials(ifNeeded: false);
    final updates = [update1];
    await _updateMultipleData(context: context, updates: updates);
  }

  Future<void> updateNoticeboardData(BuildContext context) async {
    final update1 = await noticesRepository!.updateNotices(ifNeeded: false);
    final updates = [update1];
    await _updateMultipleData(context: context, updates: updates);
  }

  Future<void> updateAgendaData(BuildContext context) async {
    final update1 = await agendaRepository!.updateAllAgenda(ifNeeded: false);
    final update2 = await lessonsRepository!.updateAllLessons(ifNeeded: false);

    final updates = [update1, update2];
    await _updateMultipleData(context: context, updates: updates);
    await updateNextEventWidget();
  }

  Future<void> updateSubjects(BuildContext context) async {
    final update1 = await subjectsRepository!.updateSubjects(ifNeeded: false);
    final update2 = await lessonsRepository!.updateAllLessons(ifNeeded: false);

    final updates = [update1, update2];
    await _updateMultipleData(context: context, updates: updates);
  }

  Future<void> updateGradesData({
    required BuildContext context,
    required GradesPagesDomainModel? gradesSections,
  }) async {
    if (gradesSections == null ||
        gradesSections.grades.isEmpty ||
        gradesSections.periodsWithGrades.isEmpty ||
        gradesSections.periodsWithGrades.first.gradesForList.isEmpty) {
      final update1 = await gradesRepository!.updateGrades(ifNeeded: false);
      final update2 = await periodsRepository!.updatePeriods(ifNeeded: false);
      final update3 = await subjectsRepository!.updateSubjects(ifNeeded: false);

      final updates = [update1, update2, update3];

      await _updateMultipleData(context: context, updates: updates);
    } else {
      final update1 = await gradesRepository!.updateGrades(ifNeeded: false);
      final updates = [update1];

      await _updateMultipleData(context: context, updates: updates);
    }
  }

  Future<void> _updateMultipleData({
    required List<Either<Failure, Success>> updates,
    required BuildContext context,
  }) async {
    for (final update in updates) {
      if (update.isLeft()) {
        final message = update.fold(
          (l) => l.localizedDescription(context),
          (r) => '',
        );

        _showErrorSnackbar(context, message);
        return;
      }
    }
    await _notifyNewContent();
  }

  Future<void> _notifyNewContent() {
    return LocalContentNotificationService(
      database: sl(),
      preferences: sharedPreferences!,
      notifications: LocalNotification((payload) async {}),
    ).notifyNewContent();
  }

  Future<void> _syncHomeworks({required bool notify}) async {
    try {
      final datasource = sl<HomeworkRemoteDatasource>();
      final database = sl<SRDatabase>();
      final previous = datasource.getCachedHomeworks();
      final current = await datasource.refresh();
      await syncHomeworkAgendaEvents(
        agendaLocalDatasource: database.agendaLocalDatasource,
        homeworks: current,
      );
      if (!notify || previous.isEmpty ||
          !(sharedPreferences!.getBool(PrefsConstants.didacticsNotifications) ?? true)) return;
      final ids = previous.map((item) => item.id).toSet();
      for (final item in current.where((item) => !ids.contains(item.id))) {
        await LocalNotification((_) async {}).showNotificationWithDefaultSound(
          item.id.hashCode, 'Nuovo compito', 'Nuovo contenuto disponibile');
      }
    } catch (_) {
      // ponytail: homework must not block the existing school-data sync.
    }
  }

  void _showErrorSnackbar(BuildContext context, String? failure) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failure ??
              AppLocalizations.of(context)!.translate('update_error_snackbar')!,
        ),
      ),
    );
  }

  Future<List<dynamic>> updateAllData(
    String? databaseName,
  ) async {
    Fimber.i('🔄 [UpdateMANAGER] Updating periods and subjects');

    await Future.wait([
      agendaRepository!.updateAllAgenda(ifNeeded: false),
      lessonsRepository!.updateAllLessons(ifNeeded: false),
      gradesRepository!.updateGrades(ifNeeded: false),
    ]);

    await Future.wait([
      periodsRepository!.updatePeriods(ifNeeded: false),
      subjectsRepository!.updateSubjects(ifNeeded: false),
    ]);

    Fimber.i(
      '🔄 [UpdateMANAGER] Setting lastUpdateAllData & lastUpdateVitalData to now',
    );

    await sharedPreferences!.setInt(
      _getAccountBasedPreferenceName(
        name: PrefsConstants.lastUpdateAllData,
        databaseName: databaseName,
      ),
      DateTime.now().millisecondsSinceEpoch,
    );

    await sharedPreferences!.setInt(
      _getAccountBasedPreferenceName(
        name: PrefsConstants.lastUpdateVitalData,
        databaseName: databaseName,
      ),
      DateTime.now().millisecondsSinceEpoch,
    );

    final updates = await Future.wait([
      absencesRepository!.updateAbsences(),
      noticesRepository!.updateNotices(ifNeeded: false),
      notesRepository!.updateNotes(),
      didacticsRepository!.updateMaterials(ifNeeded: false),
      documentsRepository!.updateDocuments(),
    ]);
    await updateNextEventWidget();
    return updates;
  }

  bool _needToUpdateAllData({
    required String? databaseName,
  }) {
    final lastUpdate = sharedPreferences!.getInt(
      _getAccountBasedPreferenceName(
        name: PrefsConstants.lastUpdateAllData,
        databaseName: databaseName,
      ),
    );

    final now = DateTime.now();

    final fiftyDaysAgo = now.subtract(Duration(days: 50));
    final hundredEightyDaysAgo = now.subtract(Duration(days: 180));

    final date = _date(lastUpdate);
    // questo significa che non ha mai aggiornato i dati vitali, quindi è la prima volta che usa l'app.
    if (lastUpdate == null) {
      return true;
      // se sono passati 15 giorni ed è settembre
    } else if (date!.isBefore(fiftyDaysAgo) && _isSemptember(now)) {
      return true;
    } else if (date.isBefore(hundredEightyDaysAgo)) {
      return true;
    }

    return false;
  }

  Future<bool> _needUpdateVitalData({
    required String? databaseName,
  }) async {
    final lastUpdate = sharedPreferences!.getInt(
      _getAccountBasedPreferenceName(
        name: PrefsConstants.lastUpdateVitalData,
        databaseName: databaseName,
      ),
    );

    // non dovrebbe succedere mai, ma mettiamolo nel caso
    if (lastUpdate == null) {
      return true;
    }

    final thirtyDaysAgo = DateTime.now().subtract(Duration(days: 15));

    if (_date(lastUpdate)!.isBefore(thirtyDaysAgo)) {
      return true;
    } else {
      // controlliamo e i periodi sono vuoti o è presente una data vecchia
      final needToUpdatePeriods =
          await periodsRepository!.needToUpdatePeriods();

      final needToUpdateResponse = needToUpdatePeriods.fold(
        (failure) => false,
        (r) => r,
      );

      if (needToUpdateResponse) {
        return true;
      }

      final _needToUpdateSubjects =
          await subjectsRepository!.needToUpdateSubjects();
      final needToUpdateSubjects = _needToUpdateSubjects.fold(
        (failure) => false,
        (r) => r,
      );

      if (needToUpdateSubjects) {
        return false;
      }
    }

    return false;
  }

  bool _isSemptember(
    DateTime date,
  ) {
    return date.month == DateTime.september;
  }

  DateTime? _date(
    int? milliseconds,
  ) {
    if (milliseconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  String _getAccountBasedPreferenceName({
    required String name,
    required String? databaseName,
  }) {
    if (databaseName == PrefsConstants.databaseNameBeforeMigration) {
      return name;
    } else {
      return '$name$databaseName';
    }
  }
}
