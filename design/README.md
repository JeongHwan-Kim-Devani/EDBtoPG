# EPAS_PRECHECK Design Final (v2.0)

## Final Design
- Reference: `../reference/report_17_260326111240/ds1.html`
- Final prototype: `epas_precheck_v2.0_prototype.html`
- Applied script: `../EPAS_PRECHECK/epas_precheck_v2.0.sh`

## Scope
- Summary and Details information architecture alignment
- Detail chip navigation and section-specific content rendering
- Status visualization normalization (`높음`, `중간`, `낮음`)
- Donut legend expansion (`고영향도`, `중영향도`, `저영향도`, `영향없음`)
- Description column Korean text output

## How To Open
```powershell
start design/epas_precheck_v2.0_prototype.html
```

## Run
```bash
bash EPAS_PRECHECK/epas_precheck_v2.0.sh -d <DBNAME> -U <USER> -o ./out
```

## Completion Notes
- The final v2.0 wireframe is reflected in the single-file report generator.
- SH/SQL responsibility was consolidated and component logic was refactored for maintainability.
- Core rendering logic was simplified to reduce duplicated conditions and repeated scans.
