import { Injectable } from '@nestjs/common';

interface HttpMetricLabels {
  method: string;
  path: string;
  service: string;
  statusCode: string;
}

interface HttpMetricRecord {
  bucketCounts: number[];
  count: number;
  durationSeconds: number;
  labels: HttpMetricLabels;
}

@Injectable()
export class MetricsService {
  private static readonly httpDurationBuckets = [
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10,
  ];

  private readonly startedAt = Date.now();

  private readonly httpRequests = new Map<string, HttpMetricRecord>();

  recordHttpRequest(input: {
    durationMs: number;
    method: string;
    path: string;
    statusCode: number;
  }): void {
    const labels: HttpMetricLabels = {
      method: input.method.toUpperCase(),
      path: input.path,
      service: process.env.SERVICE_NAME ?? 'unknown-service',
      statusCode: String(input.statusCode),
    };

    const key = JSON.stringify(labels);
    const durationSeconds = input.durationMs / 1000;

    const current = this.httpRequests.get(key) ?? {
      bucketCounts: MetricsService.httpDurationBuckets.map(() => 0),
      count: 0,
      durationSeconds: 0,
      labels,
    };

    current.count += 1;
    current.durationSeconds += durationSeconds;

    MetricsService.httpDurationBuckets.forEach((upperBound, index) => {
      if (durationSeconds <= upperBound) {
        current.bucketCounts[index] += 1;
      }
    });

    this.httpRequests.set(key, current);
  }

  scrape(): string {
    const service = process.env.SERVICE_NAME ?? 'unknown-service';
    const memory = process.memoryUsage();

    const lines = [
      '# HELP vaultbank_service_info Service identity for this process.',
      '# TYPE vaultbank_service_info gauge',
      `vaultbank_service_info{service="${this.escapeLabel(service)}"} 1`,

      '# HELP process_uptime_seconds Process uptime in seconds.',
      '# TYPE process_uptime_seconds gauge',
      `process_uptime_seconds ${((Date.now() - this.startedAt) / 1000).toFixed(
        3,
      )}`,

      '# HELP nodejs_heap_used_bytes Node.js heap currently used.',
      '# TYPE nodejs_heap_used_bytes gauge',
      `nodejs_heap_used_bytes ${memory.heapUsed}`,

      '# HELP nodejs_resident_memory_bytes Node.js resident set size.',
      '# TYPE nodejs_resident_memory_bytes gauge',
      `nodejs_resident_memory_bytes ${memory.rss}`,

      '# HELP http_requests_total Total HTTP requests handled.',
      '# TYPE http_requests_total counter',
    ];

    for (const metric of this.httpRequests.values()) {
      lines.push(
        `http_requests_total${this.formatLabels(metric.labels)} ${metric.count}`,
      );
    }

    lines.push(
      '# HELP http_request_duration_seconds HTTP request duration in seconds.',
      '# TYPE http_request_duration_seconds histogram',
    );

    for (const metric of this.httpRequests.values()) {
      MetricsService.httpDurationBuckets.forEach((upperBound, index) => {
        lines.push(
          `http_request_duration_seconds_bucket${this.formatBucketLabels(
            metric.labels,
            String(upperBound),
          )} ${metric.bucketCounts[index]}`,
        );
      });

      lines.push(
        `http_request_duration_seconds_bucket${this.formatBucketLabels(
          metric.labels,
          '+Inf',
        )} ${metric.count}`,
        `http_request_duration_seconds_count${this.formatLabels(
          metric.labels,
        )} ${metric.count}`,
        `http_request_duration_seconds_sum${this.formatLabels(
          metric.labels,
        )} ${metric.durationSeconds.toFixed(6)}`,
      );
    }

    return `${lines.join('\n')}\n`;
  }

  private formatBucketLabels(
    labels: HttpMetricLabels,
    upperBound: string,
  ): string {
    const base = this.formatLabels(labels);

    return `${base.slice(0, -1)},le="${this.escapeLabel(upperBound)}"}`;
  }

  private formatLabels(labels: HttpMetricLabels): string {
    const pairs = (Object.keys(labels) as Array<keyof HttpMetricLabels>).map(
      (key) => `${key}="${this.escapeLabel(labels[key])}"`,
    );

    return `{${pairs.join(',')}}`;
  }

  private escapeLabel(value: string): string {
    return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  }
}
