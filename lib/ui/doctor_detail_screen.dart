import 'package:flutter/material.dart';

import '../data/procedure.dart';
import '../data/procedure_repository.dart';
import '../data/user_doctor.dart';
import 'formatters.dart';
import 'procedure_detail_screen.dart';
import 'procedure_form_screen.dart';
import 'procedure_icon_resolver.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

/// Doctor profile with treatments synced from the user's passport procedures.
class DoctorDetailScreen extends StatelessWidget {
  const DoctorDetailScreen({
    super.key,
    required this.repo,
    required this.doctorKey,
  });

  final ProcedureRepository repo;
  final String doctorKey;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final doctors = userDoctorsFromProcedures(repo.allDone());
        UserDoctor? doctor;
        for (final d in doctors) {
          if (d.key == doctorKey) {
            doctor = d;
            break;
          }
        }

        return Stack(
          children: [
            const Step2WarmBackground(),
            Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: doctor == null
                    ? _EmptyDoctor(onBack: () => Navigator.of(context).maybePop())
                    : _DoctorBody(repo: repo, doctor: doctor),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyDoctor extends StatelessWidget {
  const _EmptyDoctor({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _CircleBack(onTap: onBack),
          ),
        ),
        const Spacer(),
        Text(
          'This doctor is no longer linked to any treatments.',
          textAlign: TextAlign.center,
          style: ProcedureSelectionTypography.body(size: 14, color: ProcedureSelectionTheme.muted),
        ),
        const Spacer(),
      ],
    );
  }
}

class _DoctorBody extends StatelessWidget {
  const _DoctorBody({required this.repo, required this.doctor});

  final ProcedureRepository repo;
  final UserDoctor doctor;

  Future<void> _addTreatment(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProcedureFormScreen(repo: repo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final clinic = doctor.clinicLine;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Row(
            children: [
              _CircleBack(onTap: () => Navigator.of(context).maybePop()),
              const Spacer(),
              ProcedureGlassSurface(
                borderRadius: BorderRadius.circular(999),
                compact: true,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => _addTreatment(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Text(
                        '+ Add treatment',
                        style: ProcedureSelectionTypography.label(
                          size: 12,
                          weight: FontWeight.w700,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
            illuminated: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: ProcedureSelectionTheme.buttonPrimary,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      doctor.initials,
                      style: ProcedureSelectionTypography.label(
                        size: 18,
                        weight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          doctor.name,
                          style: ProcedureSelectionTypography.display(
                            size: 18,
                            color: ProcedureSelectionTheme.ink,
                          ),
                        ),
                        if (clinic != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            clinic,
                            style: ProcedureSelectionTypography.body(
                              size: 12,
                              color: ProcedureSelectionTheme.muted,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Text(
                          doctor.treatmentCountLabel,
                          style: ProcedureSelectionTypography.label(
                            size: 11,
                            weight: FontWeight.w700,
                            color: ProcedureSelectionTheme.sectionLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'TREATMENTS',
            style: ProcedureSelectionTypography.label(
              size: 10,
              weight: FontWeight.w800,
              color: ProcedureSelectionTheme.sectionLabel,
            ).copyWith(letterSpacing: 2.0),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: doctor.procedures.isEmpty
              ? Center(
                  child: Text(
                    'No treatments yet.',
                    style: ProcedureSelectionTypography.body(
                      size: 13,
                      color: ProcedureSelectionTheme.muted,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  itemCount: doctor.procedures.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final p = doctor.procedures[i];
                    return _TreatmentRow(
                      procedure: p,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ProcedureDetailScreen(repo: repo, procedureId: p.id),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _TreatmentRow extends StatelessWidget {
  const _TreatmentRow({required this.procedure, required this.onTap});

  final Procedure procedure;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zones = procedure.zones.where((z) => z.trim().isNotEmpty).take(3).join(', ');
    final icon = procedureIconFor(procedure);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(16),
          compact: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: ProcedureSelectionTheme.buttonPrimary.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: icon.asset != null
                      ? Image.asset(icon.asset!, width: 20, height: 20, fit: BoxFit.contain)
                      : Text(icon.emoji ?? '✦', style: const TextStyle(fontSize: 16)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        procedure.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProcedureSelectionTypography.label(
                          size: 14,
                          weight: FontWeight.w700,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          formatDate(procedure.date),
                          if (zones.isNotEmpty) zones,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProcedureSelectionTypography.body(
                          size: 11,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: ProcedureSelectionTheme.muted.withValues(alpha: 0.7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleBack extends StatelessWidget {
  const _CircleBack({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(999),
      compact: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: const SizedBox(
            width: 40,
            height: 40,
            child: Icon(Icons.chevron_left_rounded, size: 22, color: ProcedureSelectionTheme.ink),
          ),
        ),
      ),
    );
  }
}
