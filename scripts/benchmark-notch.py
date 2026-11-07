#!/usr/bin/env python3
"""Run optimized benchmarks from a frozen source copy and retain honest coverage."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent


def manifest(root):
    files = [root / 'Package.swift']
    for folder in ('Sources', 'Tests'):
        files += sorted((root / folder).rglob('*.swift'))
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--samples', type=int, default=10)
    parser.add_argument('--soak-seconds', type=float, default=10)
    args = parser.parse_args()
    if not 5 <= args.samples <= 1000 or not 3 <= args.soak_seconds <= 3600:
        parser.error('samples must be 5–1000; soak-seconds must be 3–3600')
    output = (args.output or ROOT / '.build/benchmarks' / datetime.now(timezone.utc).strftime('notch-%Y%m%dT%H%M%SZ')).resolve()
    output.mkdir(parents=True, exist_ok=False)
    snapshot = output / 'source'
    snapshot.mkdir()
    before = manifest(ROOT)
    shutil.copy2(ROOT / 'Package.swift', snapshot / 'Package.swift')
    for folder in ('Sources', 'Tests'):
        shutil.copytree(ROOT / folder, snapshot / folder)
    if before != manifest(ROOT) or before != manifest(snapshot):
        raise RuntimeError('Sources changed while copying. Rerun to obtain a consistent snapshot.')
    (output / 'source-sha256.json').write_text(json.dumps(before, indent=2))
    environment = {}
    for key, command in [('swift', ['swift', '--version']), ('os', ['sw_vers']),
                         ('hardware', ['sysctl', '-n', 'hw.model', 'hw.memsize', 'hw.ncpu']),
                         ('revision', ['git', 'rev-parse', 'HEAD']), ('workingTree', ['git', 'status', '--short'])]:
        environment[key] = subprocess.run(command, cwd=ROOT, capture_output=True, text=True).stdout.strip()
    environment.update(samples=args.samples, soakSeconds=args.soak_seconds, snapshot=str(snapshot))
    (output / 'environment.json').write_text(json.dumps(environment, indent=2))
    env = dict(os.environ, NOTCH_WHOLE_APP_BENCHMARK='1', NOTCH_CODEX_BENCHMARK='1',
               NOTCH_BENCHMARK_DIR=str(output), NOTCH_BENCHMARK_OUTPUT=str(output / 'codex.json'),
               NOTCH_BENCHMARK_SAMPLES=str(args.samples), NOTCH_BENCHMARK_SOAK_SECONDS=str(args.soak_seconds),
               NOTCH_BENCHMARK_LOG=str(output / 'synthetic-app.log'))
    command = ['swift', 'test', '--package-path', str(snapshot), '-c', 'release', '-Xswiftc', '-DNOTCH_BENCHMARK',
               '--filter', 'NotchPerformanceTests|CodexPerformanceTests|CodexRolloutTests|CodexSessionTests|ReleaseSafetyTests|ScreenshotPipelineTests',
               '--skip', 'CodexSessionTests/(testClaudeStillReplacesSessionWhenProcessIsReused|testMultipleCodexThreadsCanShareProcessAndProviderIDsCannotCollide)',
               '--xunit-output', str(output / 'tests.xml')]
    print(f'Frozen source: {snapshot}\nReports: {output}', flush=True)
    with (output / 'tests.log').open('w') as log:
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            print(line, end='', flush=True)
            log.write(line)
        code = process.wait()
    matrix = json.loads((ROOT / 'docs/notch-benchmark-scenarios.json').read_text())
    actual = {}
    if (output / 'notch.json').exists():
        actual = {r['id']: r for r in json.loads((output / 'notch.json').read_text())['results']}
    for scenario in matrix:
        prefixes = scenario.get('automatedPrefixes', [])
        matches = [r for name, r in actual.items() if any(name.startswith(p) for p in prefixes)]
        if scenario['mode'] == 'excluded':
            scenario['status'] = 'excluded'
        elif scenario['mode'] == 'live':
            scenario['status'] = 'not-run'
        elif scenario['id'] == 'codex-components':
            scenario['status'] = 'passed' if code == 0 and (output / 'codex.json').exists() else 'incomplete'
        else:
            scenario['status'] = ('passed' if matches and all(r['status'] == 'passed' for r in matches)
                                  and code == 0 else 'incomplete')
        scenario['measuredOperations'] = [r['id'] for r in matches]
    coverage = {'automatedExitCode': code, 'scope': 'All Notch feature areas except Claude; live checks remain separate',
                'scenarios': matrix, 'liveAppMeasured': False, 'batteryMeasured': False,
                'testEvidence': ['tests.log'] + (['tests.xml'] if (output / 'tests.xml').exists() else [])}
    (output / 'coverage.json').write_text(json.dumps(coverage, indent=2))
    lines = ['# Notch benchmark results', '', f'Automated command exit: {code}. Claude excluded.', '',
             '| Area | Status | Mode |', '| --- | --- | --- |']
    lines += [f"| {s['id']} | {s['status']} | {s['mode']} |" for s in matrix]
    lines += ['', 'See notch.json and codex.json for raw measurements, tests.log for correctness,',
              'renders/ for visual review, and environment.json/source-sha256.json for provenance.',
              'Live integrations, compositor FPS and battery impact are not established by these fixture tests.']
    if not (output / 'tests.xml').exists():
        lines += ['', 'This SwiftPM toolchain did not emit the requested tests.xml; tests.log retains the XCTest summary.']
    lines += ['', '## Whole-app fixture measurements', '', '| Operation | p95 ms | Mean CPU ms |', '| --- | ---: | ---: |']
    for name, result in actual.items():
        if 'wallP95MS' in result:
            lines.append(f"| {name} | {result['wallP95MS']:.3f} | {result['meanCPUMS']:.3f} |")
        elif name == 'mixed.soak':
            lines += ['', f"Mixed harness: {result['durationSeconds']:.1f} s, {result['actualOneCoreCPUPercent']:.2f}% of one core, "
                      f"wake lateness p95 {result['mainActorWakeLatenessP95MS']:.2f} ms. Includes forced bitmap capture."]
    (output / 'REPORT.md').write_text('\n'.join(lines) + '\n')
    print(f'\nCoverage report: {output / "REPORT.md"}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
