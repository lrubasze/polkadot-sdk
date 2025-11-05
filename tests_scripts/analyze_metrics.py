#!/usr/bin/env python3
"""
Analyze blockchain test metrics from log files.

This script parses collator logs and top (CPU) monitoring logs to extract
performance metrics within a specified time range.
"""

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Tuple


@dataclass
class BlockMetric:
    """Represents metrics for a single block preparation."""
    block_number: int
    duration_ms: int
    extrinsics_count: int
    timestamp: str
    extrinsics_kb: Optional[float] = None  # Total extrinsics size in KB


@dataclass
class CPUMetric:
    """Represents CPU usage at a point in time."""
    timestamp: str
    cpu_percent: float


@dataclass
class AnalysisResults:
    """Container for all analysis results."""
    # Block metrics
    blocks: List[BlockMetric]
    total_blocks_found: int  # Total blocks found in logs
    filtered_blocks_count: int  # Blocks with extrinsics > 100
    avg_duration_ms: float
    min_duration_ms: int
    max_duration_ms: int
    avg_extrinsics: float
    avg_extrinsics_kb: float  # Average KB per extrinsic

    # CPU metrics
    cpu_samples: int
    avg_cpu_percent: float
    min_cpu_percent: float
    max_cpu_percent: float


class LogParser:
    """Parses logs and extracts metrics."""

    # Regex patterns
    TIMESTAMP_PATTERN = re.compile(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
    BLOCK_PREP_PATTERN = re.compile(
        r'Prepared block for propo.*at (\d+) \((\d+) ms\).*extrinsics_count: (\d+)'
    )
    POV_SIZE_PATTERN = re.compile(
        r'PoV size.*extrinsics_kb=([\d.]+)'
    )

    @staticmethod
    def parse_timestamp(line: str) -> Optional[str]:
        """Extract timestamp from log line (YYYY-MM-DD HH:MM:SS)."""
        match = LogParser.TIMESTAMP_PATTERN.match(line)
        return match.group(0) if match else None

    @staticmethod
    def is_in_time_range(timestamp: str, start: str, end: str) -> bool:
        """Check if timestamp is within the range [start, end]."""
        return start <= timestamp <= end

    def parse_collator_log(
        self,
        log_path: Path,
        start_time: str,
        end_time: str
    ) -> List[BlockMetric]:
        """
        Parse collator log file and extract block preparation metrics.
        Also matches PoV size logs to get extrinsics size information.

        Args:
            log_path: Path to collator log file
            start_time: Start timestamp (YYYY-MM-DD HH:MM:SS)
            end_time: End timestamp (YYYY-MM-DD HH:MM:SS)

        Returns:
            List of BlockMetric objects within the time range
        """
        from datetime import datetime, timedelta

        blocks = []
        pov_sizes = []  # Store (timestamp, extrinsics_kb) tuples

        try:
            # First pass: collect all blocks and PoV sizes
            with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    timestamp = self.parse_timestamp(line)
                    if not timestamp:
                        continue

                    if not self.is_in_time_range(timestamp, start_time, end_time):
                        continue

                    # Look for block preparation messages
                    match = self.BLOCK_PREP_PATTERN.search(line)
                    if match:
                        block_number = int(match.group(1))
                        duration_ms = int(match.group(2))
                        extrinsics_count = int(match.group(3))

                        blocks.append(BlockMetric(
                            block_number=block_number,
                            duration_ms=duration_ms,
                            extrinsics_count=extrinsics_count,
                            timestamp=timestamp,
                            extrinsics_kb=None
                        ))
                        continue

                    # Look for PoV size messages
                    pov_match = self.POV_SIZE_PATTERN.search(line)
                    if pov_match:
                        extrinsics_kb = float(pov_match.group(1))
                        pov_sizes.append((timestamp, extrinsics_kb))

            # Second pass: match PoV sizes to blocks
            # PoV logs appear shortly after block preparation (typically within 1 second)
            for block in blocks:
                block_time = datetime.strptime(block.timestamp, '%Y-%m-%d %H:%M:%S')

                # Find the nearest PoV size log within 2 seconds after the block
                best_match = None
                min_delta = timedelta(seconds=2)

                for pov_timestamp, extrinsics_kb in pov_sizes:
                    pov_time = datetime.strptime(pov_timestamp, '%Y-%m-%d %H:%M:%S')
                    delta = pov_time - block_time

                    # PoV log should be after the block, within 2 seconds
                    if timedelta(0) <= delta < min_delta:
                        best_match = extrinsics_kb
                        min_delta = delta

                if best_match is not None:
                    block.extrinsics_kb = best_match

        except FileNotFoundError:
            print(f"Error: Collator log file not found: {log_path}", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"Error parsing collator log: {e}", file=sys.stderr)
            sys.exit(1)

        return blocks

    def parse_top_log(
        self,
        log_path: Path,
        start_time: str,
        end_time: str
    ) -> List[CPUMetric]:
        """
        Parse top monitoring log file and extract CPU metrics.

        Format: YYYY-MM-DD HH:MM:SS PID CPU% MEM

        Args:
            log_path: Path to top log file
            start_time: Start timestamp (YYYY-MM-DD HH:MM:SS)
            end_time: End timestamp (YYYY-MM-DD HH:MM:SS)

        Returns:
            List of CPUMetric objects within the time range
        """
        cpu_metrics = []

        try:
            with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    parts = line.strip().split()

                    # Expected format: YYYY-MM-DD HH:MM:SS PID CPU% ...
                    if len(parts) < 4:
                        continue

                    # Check if first two parts form a valid timestamp
                    if not (re.match(r'^\d{4}-\d{2}-\d{2}$', parts[0]) and
                            re.match(r'^\d{2}:\d{2}:\d{2}$', parts[1])):
                        continue

                    timestamp = f"{parts[0]} {parts[1]}"

                    if not self.is_in_time_range(timestamp, start_time, end_time):
                        continue

                    # Parse CPU percentage (4th column)
                    try:
                        cpu_percent = float(parts[3])
                        cpu_metrics.append(CPUMetric(
                            timestamp=timestamp,
                            cpu_percent=cpu_percent
                        ))
                    except (ValueError, IndexError):
                        continue

        except FileNotFoundError:
            print(f"Error: Top log file not found: {log_path}", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"Error parsing top log: {e}", file=sys.stderr)
            sys.exit(1)

        return cpu_metrics


class MetricsAnalyzer:
    """Analyzes parsed metrics and generates statistics."""

    # Minimum extrinsics threshold for block filtering
    MIN_EXTRINSICS_THRESHOLD = 100

    @staticmethod
    def analyze_blocks(blocks: List[BlockMetric]) -> Tuple[int, int, float, int, int, float, float]:
        """
        Analyze block metrics and compute statistics.
        Only considers blocks with extrinsics > MIN_EXTRINSICS_THRESHOLD.

        Returns:
            (total_found, filtered_count, avg_duration, min_duration, max_duration, avg_extrinsics, avg_extrinsics_kb)
        """
        total_blocks = len(blocks)

        if not blocks:
            return 0, 0, 0.0, 0, 0, 0.0, 0.0

        # Filter blocks with extrinsics > threshold
        filtered_blocks = [b for b in blocks if b.extrinsics_count > MetricsAnalyzer.MIN_EXTRINSICS_THRESHOLD]

        if not filtered_blocks:
            return total_blocks, 0, 0.0, 0, 0, 0.0, 0.0

        durations = [b.duration_ms for b in filtered_blocks]
        extrinsics = [b.extrinsics_count for b in filtered_blocks]

        # Calculate average KB per extrinsic (only for blocks with size data)
        blocks_with_size = [b for b in filtered_blocks if b.extrinsics_kb is not None and b.extrinsics_count > 0]
        if blocks_with_size:
            # Average KB per extrinsic across all blocks
            total_kb_per_extrinsic = sum(b.extrinsics_kb / b.extrinsics_count for b in blocks_with_size)
            avg_extrinsics_kb = total_kb_per_extrinsic / len(blocks_with_size)
        else:
            avg_extrinsics_kb = 0.0

        return (
            total_blocks,
            len(filtered_blocks),
            sum(durations) / len(durations),
            min(durations),
            max(durations),
            sum(extrinsics) / len(extrinsics),
            avg_extrinsics_kb
        )

    @staticmethod
    def analyze_cpu(cpu_metrics: List[CPUMetric]) -> Tuple[int, float, float, float]:
        """
        Analyze CPU metrics and compute statistics.

        Returns:
            (sample_count, avg_cpu, min_cpu, max_cpu)
        """
        if not cpu_metrics:
            return 0, 0.0, 0.0, 0.0

        cpu_values = [m.cpu_percent for m in cpu_metrics]

        return (
            len(cpu_values),
            sum(cpu_values) / len(cpu_values),
            min(cpu_values),
            max(cpu_values)
        )

    @staticmethod
    def create_results(
        blocks: List[BlockMetric],
        cpu_metrics: List[CPUMetric]
    ) -> AnalysisResults:
        """Create AnalysisResults from parsed data."""
        block_stats = MetricsAnalyzer.analyze_blocks(blocks)
        cpu_stats = MetricsAnalyzer.analyze_cpu(cpu_metrics)

        # Filter blocks for display (only those with extrinsics > threshold)
        filtered_blocks = [b for b in blocks if b.extrinsics_count > MetricsAnalyzer.MIN_EXTRINSICS_THRESHOLD]

        return AnalysisResults(
            blocks=filtered_blocks,  # Only store filtered blocks
            total_blocks_found=block_stats[0],
            filtered_blocks_count=block_stats[1],
            avg_duration_ms=block_stats[2],
            min_duration_ms=block_stats[3],
            max_duration_ms=block_stats[4],
            avg_extrinsics=block_stats[5],
            avg_extrinsics_kb=block_stats[6],
            cpu_samples=cpu_stats[0],
            avg_cpu_percent=cpu_stats[1],
            min_cpu_percent=cpu_stats[2],
            max_cpu_percent=cpu_stats[3]
        )


class OutputFormatter:
    """Formats analysis results for output."""

    @staticmethod
    def format_summary(results: AnalysisResults, start_time: str, end_time: str) -> str:
        """
        Format results as a human-readable summary.

        Args:
            results: Analysis results
            start_time: Start timestamp
            end_time: End timestamp

        Returns:
            Formatted summary string
        """
        lines = [
            "",
            "=" * 72,
            "  Performance Analysis Results",
            f"  Time Range: {start_time} to {end_time}",
            "=" * 72,
            "",
            "--- CPU Usage Analysis ---",
            f"Filtering by timestamp range: {start_time} to {end_time}",
        ]

        if results.cpu_samples > 0:
            lines.extend([
                f"Samples: {results.cpu_samples}",
                f"Avg CPU: {results.avg_cpu_percent:.2f}%",
                f"Min CPU: {results.min_cpu_percent:.2f}%",
                f"Max CPU: {results.max_cpu_percent:.2f}%",
            ])
        else:
            lines.append("No CPU data found in time range")

        lines.extend([
            "",
            "--- Block Preparation Metrics ---",
            f"Filtering by timestamp range: {start_time} to {end_time}",
            f"Only analyzing blocks with extrinsics > {MetricsAnalyzer.MIN_EXTRINSICS_THRESHOLD}",
        ])

        if results.total_blocks_found > 0:
            lines.append(f"Total blocks found: {results.total_blocks_found}")
            lines.append(f"Blocks with extrinsics > {MetricsAnalyzer.MIN_EXTRINSICS_THRESHOLD}: {results.filtered_blocks_count}")

            if results.filtered_blocks_count > 0:
                # Show individual filtered blocks
                lines.append("")
                lines.append("Block,Duration(ms),Extrinsics,Extrinsics_KB")
                for block in results.blocks:
                    ext_kb_str = f"{block.extrinsics_kb:.4f}" if block.extrinsics_kb is not None else "N/A"
                    lines.append(f"{block.block_number},{block.duration_ms},{block.extrinsics_count},{ext_kb_str}")

                lines.extend([
                    "",
                    f"Avg duration: {results.avg_duration_ms:.2f} ms",
                    f"Min duration: {results.min_duration_ms} ms",
                    f"Max duration: {results.max_duration_ms} ms",
                    f"Avg extrinsics: {results.avg_extrinsics:.2f}",
                    f"Avg KB/extrinsic: {results.avg_extrinsics_kb:.4f} KB",
                ])
            else:
                lines.append(f"No blocks found with extrinsics > {MetricsAnalyzer.MIN_EXTRINSICS_THRESHOLD}")
        else:
            lines.append("No block preparation data found")

        lines.extend([
            "",
            "=" * 72,
        ])

        return "\n".join(lines)

    @staticmethod
    def append_to_csv(
        csv_path: Path,
        interest_cache: str,
        log_level: str,
        results: AnalysisResults
    ):
        """
        Append results to CSV file.

        CSV format: interest_cache;log_level;blocks_analyzed;proposal_min_ms;proposal_max_ms;
                    proposal_avg_ms;avg_extrinsics;cpu_min_pct;cpu_max_pct;cpu_avg_pct
        """
        try:
            with open(csv_path, 'a') as f:
                f.write(f"{interest_cache};{log_level};{results.filtered_blocks_count};"
                       f"{results.min_duration_ms};{results.max_duration_ms};"
                       f"{results.avg_duration_ms:.2f};{results.avg_extrinsics:.2f};"
                       f"{results.min_cpu_percent:.2f};{results.max_cpu_percent:.2f};"
                       f"{results.avg_cpu_percent:.2f}\n")
        except Exception as e:
            print(f"Error appending to CSV: {e}", file=sys.stderr)
            sys.exit(1)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Analyze blockchain test metrics from log files',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument(
        '--collator-log',
        type=Path,
        required=True,
        help='Path to collator log file'
    )
    parser.add_argument(
        '--top-log',
        type=Path,
        required=True,
        help='Path to top (CPU monitoring) log file'
    )
    parser.add_argument(
        '--start-time',
        required=True,
        help='Start timestamp (YYYY-MM-DD HH:MM:SS)'
    )
    parser.add_argument(
        '--end-time',
        required=True,
        help='End timestamp (YYYY-MM-DD HH:MM:SS)'
    )
    parser.add_argument(
        '--output',
        type=Path,
        help='Output file for summary (optional, prints to stdout if not specified)'
    )
    parser.add_argument(
        '--csv-file',
        type=Path,
        help='CSV file to append results to (optional)'
    )
    parser.add_argument(
        '--interest-cache',
        help='Interest cache configuration (for CSV output)'
    )
    parser.add_argument(
        '--log-level',
        help='Log level configuration (for CSV output)'
    )

    args = parser.parse_args()

    # Parse logs
    log_parser = LogParser()

    print(f"Parsing collator log: {args.collator_log}", file=sys.stderr)
    blocks = log_parser.parse_collator_log(
        args.collator_log,
        args.start_time,
        args.end_time
    )

    print(f"Parsing top log: {args.top_log}", file=sys.stderr)
    cpu_metrics = log_parser.parse_top_log(
        args.top_log,
        args.start_time,
        args.end_time
    )

    # Analyze metrics
    analyzer = MetricsAnalyzer()
    results = analyzer.create_results(blocks, cpu_metrics)

    # Format output
    formatter = OutputFormatter()
    summary = formatter.format_summary(results, args.start_time, args.end_time)

    # Write or print summary
    if args.output:
        print(f"Writing summary to: {args.output}", file=sys.stderr)
        with open(args.output, 'w') as f:
            f.write(summary)
        # Also print to stdout for compatibility with tee
        print(summary)
    else:
        print(summary)

    # Append to CSV if requested
    if args.csv_file:
        if not args.interest_cache or not args.log_level:
            print("Error: --interest-cache and --log-level required for CSV output",
                  file=sys.stderr)
            sys.exit(1)

        print(f"Appending results to: {args.csv_file}", file=sys.stderr)
        formatter.append_to_csv(
            args.csv_file,
            args.interest_cache,
            args.log_level,
            results
        )

    print("Analysis complete!", file=sys.stderr)


if __name__ == '__main__':
    main()
