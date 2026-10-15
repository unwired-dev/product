"""Custom Category comparison (spike #829).

See CUSTOM.md for commands, frozen candidates and evaluation limitations.
"""

import sys

import custom_benchmark as benchmark
import custom_report as report

if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {
        "annotate": benchmark.annotate,
        "labels": benchmark.labels,
        "adapt": benchmark.adapt,
        "score": benchmark.score,
        "evaluate": benchmark.evaluate_run,
        "keywords": benchmark.keywords,
        "agreement": benchmark.agreement,
        "templates": benchmark.templates,
        "golden": report.golden,
        "tables": report.tables,
        "overrides": lambda name: benchmark.write(benchmark.overrides(name)),
    }[command](*args)
