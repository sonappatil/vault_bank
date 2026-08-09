import { CallHandler, ExecutionContext } from '@nestjs/common';
import { lastValueFrom, of } from 'rxjs';
import { TransformInterceptor } from './transform.interceptor';

function contextFor(url: string): ExecutionContext {
  return {
    switchToHttp: () => ({
      getRequest: () => ({
        originalUrl: url,
      }),
    }),
  } as unknown as ExecutionContext;
}

describe('TransformInterceptor', () => {
  const interceptor = new TransformInterceptor<string>();

  it('returns Prometheus metrics without JSON wrapping', async () => {
    const metrics =
      '# HELP vaultbank_service_info Service identity\n' +
      '# TYPE vaultbank_service_info gauge\n' +
      'vaultbank_service_info{service="auth-service"} 1\n';

    const next: CallHandler<string> = {
      handle: () => of(metrics),
    };

    const result = await lastValueFrom(
      interceptor.intercept(contextFor('/v1/metrics'), next),
    );

    expect(result).toBe(metrics);
  });

  it('still wraps normal API responses', async () => {
    const next: CallHandler<string> = {
      handle: () => of('ok'),
    };

    const result = await lastValueFrom(
      interceptor.intercept(contextFor('/v1/example'), next),
    );

    expect(result).toEqual(
      expect.objectContaining({
        success: true,
        data: 'ok',
      }),
    );
  });

  it('ignores query parameters on metrics endpoint', async () => {
    const next: CallHandler<string> = {
      handle: () => of('metric_test 1\n'),
    };

    const result = await lastValueFrom(
      interceptor.intercept(contextFor('/v1/metrics?probe=true'), next),
    );

    expect(result).toBe('metric_test 1\n');
  });
});
