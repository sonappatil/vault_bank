import { MetricsService } from './metrics.service';

describe('MetricsService HTTP histogram', () => {
  afterEach(() => {
    delete process.env.SERVICE_NAME;
  });

  it('exports cumulative HTTP latency histogram buckets', () => {
    process.env.SERVICE_NAME = 'auth-service';

    const metrics = new MetricsService();

    metrics.recordHttpRequest({
      durationMs: 4,
      method: 'get',
      path: '/v1/test',
      statusCode: 200,
    });

    metrics.recordHttpRequest({
      durationMs: 10,
      method: 'get',
      path: '/v1/test',
      statusCode: 200,
    });

    metrics.recordHttpRequest({
      durationMs: 300,
      method: 'get',
      path: '/v1/test',
      statusCode: 200,
    });

    const scrape = metrics.scrape();

    expect(scrape).toContain('# TYPE http_request_duration_seconds histogram');

    expect(scrape).toContain(
      'http_request_duration_seconds_bucket' +
        '{method="GET",path="/v1/test",service="auth-service",' +
        'statusCode="200",le="0.005"} 1',
    );

    expect(scrape).toContain(
      'http_request_duration_seconds_bucket' +
        '{method="GET",path="/v1/test",service="auth-service",' +
        'statusCode="200",le="0.01"} 2',
    );

    expect(scrape).toContain(
      'http_request_duration_seconds_bucket' +
        '{method="GET",path="/v1/test",service="auth-service",' +
        'statusCode="200",le="0.25"} 2',
    );

    expect(scrape).toContain(
      'http_request_duration_seconds_bucket' +
        '{method="GET",path="/v1/test",service="auth-service",' +
        'statusCode="200",le="0.5"} 3',
    );

    expect(scrape).toContain(
      'http_request_duration_seconds_bucket' +
        '{method="GET",path="/v1/test",service="auth-service",' +
        'statusCode="200",le="+Inf"} 3',
    );

    expect(scrape).toContain(
      'http_request_duration_seconds_count' +
        '{method="GET",path="/v1/test",service="auth-service",' +
        'statusCode="200"} 3',
    );

    expect(scrape).toContain(
      'http_request_duration_seconds_sum' +
        '{method="GET",path="/v1/test",service="auth-service",' +
        'statusCode="200"} 0.314000',
    );
  });

  it('keeps statusCode available for HTTP error-rate queries', () => {
    process.env.SERVICE_NAME = 'payment-service';

    const metrics = new MetricsService();

    metrics.recordHttpRequest({
      durationMs: 50,
      method: 'post',
      path: '/v1/payments',
      statusCode: 500,
    });

    const scrape = metrics.scrape();

    expect(scrape).toContain(
      'http_requests_total' +
        '{method="POST",path="/v1/payments",' +
        'service="payment-service",statusCode="500"} 1',
    );

    expect(scrape).toContain(
      'http_request_duration_seconds_bucket' +
        '{method="POST",path="/v1/payments",' +
        'service="payment-service",statusCode="500",le="+Inf"} 1',
    );
  });
});
